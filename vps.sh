#!/usr/bin/env bash
set -Eeuo pipefail

# CrowdSec VPS node installer for a central CrowdSec LAPI.
# Fixed version based on the full troubleshooting session.
#
# What it does:
# - Removes Fail2Ban safely, with backup of /etc/fail2ban.
# - Installs CrowdSec agent.
# - Registers this VPS to the central LAPI using auto-registration token.
# - Does NOT delete local_api_credentials.yaml before registration; it uses --file properly.
# - Installs SSH/Linux collections and optional Nginx/Apache collections.
# - Installs firewall bouncer and points it to the central LAPI with shared bouncer key.
#
# Install:
#   sudo bash install-crowdsec-vps-node-fixed.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_DIR="/root/crowdsec-vps-node"
ENV_FILE="${CONFIG_DIR}/node.env"
FAIL2BAN_BACKUP_DIR="${CONFIG_DIR}/fail2ban-backup"

log() { echo -e "${BLUE}==>${NC} $*"; }
ok() { echo -e "${GREEN}OK:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
fail() { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
pause() { echo; read -rp "Нажми Enter для продолжения..." _ || true; }
is_interactive() { [[ -t 0 ]]; }
require_interactive_install() {
  if ! is_interactive; then
    fail "Интерактивная установка не работает через pipe. Скачай скрипт во временный файл и запусти его: tmp=\"\$(mktemp)\" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/vps.sh -o \"\$tmp\" && bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc"
  fi
}
prompt_default() {
  local __var_name="$1"
  local __prompt="$2"
  local __default="${3:-}"
  local __value=""
  if is_interactive; then
    read -rp "${__prompt}" __value || __value=""
  fi
  printf -v "${__var_name}" '%s' "${__value:-${__default}}"
}
tui_theme() {
  export NEWT_COLORS='
root=white,blue
border=black,lightgray
window=black,lightgray
shadow=black,black
title=red,lightgray
button=black,lightgray
actbutton=white,red
entry=black,white
label=black,lightgray
textbox=black,lightgray
'
}
bootstrap_installer_tui() {
  command -v whiptail >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || return 1
  clear || true
  echo "Preparing interactive installer..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/tmp/crowdsec-vps-bootstrap.log 2>&1 || return 1
  apt-get install -y whiptail >>/tmp/crowdsec-vps-bootstrap.log 2>&1 || return 1
  command -v whiptail >/dev/null 2>&1
}
tui_input() {
  local title="$1"
  local text="$2"
  local default="${3:-}"
  whiptail --title " ${title} " --inputbox "${text}" 10 78 "${default}" 3>&1 1>&2 2>&3
}
tui_yesno() {
  local title="$1"
  local text="$2"
  whiptail --title " ${title} " --yes-button "Да" --no-button "Нет" --yesno "${text}" 10 78
}
run_install_step() {
  local title="$1"
  shift
  local log_file
  log_file="$(mktemp)"
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title " CrowdSec VPS Node " --infobox "${title}\n\nПодробный лог пишется во временный файл." 9 72 || true
  else
    log "${title}"
  fi
  if "$@" >"${log_file}" 2>&1; then
    rm -f "${log_file}"
    return 0
  fi
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title " Ошибка: ${title} " --textbox "${log_file}" 30 110 || true
  else
    cat "${log_file}"
  fi
  rm -f "${log_file}"
  fail "Этап установки завершился ошибкой: ${title}"
}
on_error() {
  local exit_code="$?"
  local line_no="${1:-unknown}"
  fail "Сбой на строке ${line_no}, код выхода ${exit_code}"
}
trap 'on_error ${LINENO}' ERR

require_root() { [[ "${EUID}" -eq 0 ]] || fail "Запусти от root: sudo bash $0"; }

detect_debian() {
  [[ -f /etc/debian_version ]] || fail "Скрипт рассчитан на Debian или Ubuntu."
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    log "Система: ${PRETTY_NAME:-Debian/Ubuntu}"
  fi
}

load_env_if_exists() {
  if [[ -f "${ENV_FILE}" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set -u
  fi
  CENTRAL_LAPI_URL="${CENTRAL_LAPI_URL:-}"
  AUTO_REG_TOKEN="${AUTO_REG_TOKEN:-}"
  SHARED_BOUNCER_KEY="${SHARED_BOUNCER_KEY:-}"
  MACHINE_NAME="${MACHINE_NAME:-$(hostname -f 2>/dev/null || hostname)}"
  INSTALL_FIREWALL_BOUNCER="${INSTALL_FIREWALL_BOUNCER:-yes}"
  INSTALL_WEB_COLLECTIONS="${INSTALL_WEB_COLLECTIONS:-auto}"
  FIREWALL_BOUNCER_PACKAGE="${FIREWALL_BOUNCER_PACKAGE:-}"
  FIREWALL_BOUNCER_MODE="${FIREWALL_BOUNCER_MODE:-}"
}

save_env() {
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"
  cat > "${ENV_FILE}" <<ENV
CENTRAL_LAPI_URL=${CENTRAL_LAPI_URL}
AUTO_REG_TOKEN=${AUTO_REG_TOKEN}
SHARED_BOUNCER_KEY=${SHARED_BOUNCER_KEY}
MACHINE_NAME=${MACHINE_NAME}
INSTALL_FIREWALL_BOUNCER=${INSTALL_FIREWALL_BOUNCER}
INSTALL_WEB_COLLECTIONS=${INSTALL_WEB_COLLECTIONS}
FIREWALL_BOUNCER_PACKAGE=${FIREWALL_BOUNCER_PACKAGE}
FIREWALL_BOUNCER_MODE=${FIREWALL_BOUNCER_MODE}
ENV
  chmod 600 "${ENV_FILE}"
}

ask_settings() {
  load_env_if_exists
  if command -v whiptail >/dev/null 2>&1; then
    tui_theme
    whiptail --title " CrowdSec VPS Node " --msgbox "Подключение VPS к центральному CrowdSec LAPI.\n\nДанные возьми в меню центрального сервера: sudo crowdsec-central-menu" 12 78
    CENTRAL_LAPI_URL="$(tui_input "Central LAPI" "Central LAPI URL" "${CENTRAL_LAPI_URL:-http://1.2.3.4:8080}")" || exit 1
    AUTO_REG_TOKEN="$(tui_input "Central LAPI" "AUTO_REG_TOKEN" "${AUTO_REG_TOKEN:-}")" || exit 1
    SHARED_BOUNCER_KEY="$(tui_input "Firewall Bouncer" "SHARED_BOUNCER_KEY" "${SHARED_BOUNCER_KEY:-}")" || exit 1
    MACHINE_NAME="$(tui_input "Machine" "Machine name" "${MACHINE_NAME}")" || exit 1
    if tui_yesno "Firewall Bouncer" "Ставить firewall-bouncer для автоматической блокировки IP?"; then
      INSTALL_FIREWALL_BOUNCER="yes"
    else
      INSTALL_FIREWALL_BOUNCER="no"
    fi
    INSTALL_WEB_COLLECTIONS="$(whiptail --title " Web Collections " --cancel-button "Отмена" --ok-button "Select" --notags --menu "Включать web collections?" 15 78 3 \
      "auto" "Auto-detect Nginx/Apache" \
      "yes" "Enable forcibly" \
      "no" "Disable" \
      3>&1 1>&2 2>&3)" || exit 1
    [[ -n "${CENTRAL_LAPI_URL}" ]] || fail "Central LAPI URL не может быть пустым."
    [[ "${CENTRAL_LAPI_URL}" =~ ^https?://[^[:space:]]+$ ]] || fail "Central LAPI URL должен начинаться с http:// или https://"
    [[ -n "${AUTO_REG_TOKEN}" ]] || fail "AUTO_REG_TOKEN не может быть пустым."
    [[ "${AUTO_REG_TOKEN}" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "AUTO_REG_TOKEN содержит недопустимые символы."
    if [[ -n "${SHARED_BOUNCER_KEY}" ]] && [[ ! "${SHARED_BOUNCER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      fail "SHARED_BOUNCER_KEY содержит недопустимые символы."
    fi
    if [[ "${INSTALL_FIREWALL_BOUNCER}" == "yes" && -z "${SHARED_BOUNCER_KEY}" ]]; then
      fail "Для firewall-bouncer нужен SHARED_BOUNCER_KEY."
    fi
    save_env
    return
  fi
  echo
  echo "Настройка подключения VPS к центральному CrowdSec LAPI."
  echo
  echo "На центральном сервере открой:"
  echo "  sudo crowdsec-central-menu"
  echo "Пункт 2 покажет LAPI URL, AUTO_REG_TOKEN и SHARED_BOUNCER_KEY."
  echo "Перед установкой добавь внешний IP этого VPS в allowed IP/CIDR на центральном сервере."
  echo
  prompt_default input_lapi "Central LAPI URL [${CENTRAL_LAPI_URL:-http://1.2.3.4:8080}]: " "${CENTRAL_LAPI_URL:-http://1.2.3.4:8080}"
  CENTRAL_LAPI_URL="${input_lapi:-${CENTRAL_LAPI_URL}}"
  [[ -n "${CENTRAL_LAPI_URL}" ]] || fail "Central LAPI URL не может быть пустым."
  [[ "${CENTRAL_LAPI_URL}" =~ ^https?://[^[:space:]]+$ ]] || fail "Central LAPI URL должен начинаться с http:// или https://"

  prompt_default input_token "AUTO_REG_TOKEN: " "${AUTO_REG_TOKEN:-}"
  AUTO_REG_TOKEN="${input_token:-${AUTO_REG_TOKEN}}"
  [[ -n "${AUTO_REG_TOKEN}" ]] || fail "AUTO_REG_TOKEN не может быть пустым."
  [[ "${AUTO_REG_TOKEN}" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "AUTO_REG_TOKEN содержит недопустимые символы."

  prompt_default input_bouncer "SHARED_BOUNCER_KEY: " "${SHARED_BOUNCER_KEY:-}"
  SHARED_BOUNCER_KEY="${input_bouncer:-${SHARED_BOUNCER_KEY}}"
  if [[ -n "${SHARED_BOUNCER_KEY}" ]] && [[ ! "${SHARED_BOUNCER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    fail "SHARED_BOUNCER_KEY содержит недопустимые символы."
  fi

  prompt_default input_machine "Machine name [${MACHINE_NAME}]: " "${MACHINE_NAME}"
  MACHINE_NAME="${input_machine:-${MACHINE_NAME}}"

  echo
  prompt_default input_bouncer_install "Ставить firewall-bouncer для автоматической блокировки IP? [Y/n]: " "Y"
  if [[ "${input_bouncer_install:-Y}" =~ ^[Nn]$ ]]; then
    INSTALL_FIREWALL_BOUNCER="no"
  else
    INSTALL_FIREWALL_BOUNCER="yes"
  fi
  if [[ "${INSTALL_FIREWALL_BOUNCER}" == "yes" && -z "${SHARED_BOUNCER_KEY}" ]]; then
    fail "Для firewall-bouncer нужен SHARED_BOUNCER_KEY."
  fi

  echo
  echo "Если на VPS есть Nginx или Apache, можно включить collections для веб-логов."
  echo "auto - включить автоматически, если найдены nginx/apache"
  echo "yes  - включить принудительно"
  echo "no   - не включать"
  prompt_default input_web "Включать web collections? [auto]: " "auto"
  INSTALL_WEB_COLLECTIONS="${input_web:-auto}"

  save_env
}

install_base() {
  log "Устанавливаю базовые пакеты..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg lsb-release apt-transport-https python3 python3-yaml jq sudo iproute2 procps nano rsync iptables nftables whiptail less
  ok "Базовые пакеты установлены."
}

remove_fail2ban_if_installed() {
  log "Проверяю Fail2Ban..."
  local fail2ban_found="no"
  command -v fail2ban-client >/dev/null 2>&1 && fail2ban_found="yes"
  dpkg -s fail2ban >/dev/null 2>&1 && fail2ban_found="yes"
  if [[ "${fail2ban_found}" != "yes" ]]; then
    ok "Fail2Ban не установлен."
    return
  fi
  warn "Fail2Ban найден. Останавливаю, отключаю и удаляю."
  mkdir -p "${FAIL2BAN_BACKUP_DIR}"
  chmod 700 "${FAIL2BAN_BACKUP_DIR}"
  if [[ -d /etc/fail2ban ]]; then
    rsync -a /etc/fail2ban/ "${FAIL2BAN_BACKUP_DIR}/etc-fail2ban-$(date +%F-%H%M%S)/" || true
    ok "Конфиги Fail2Ban сохранены в ${FAIL2BAN_BACKUP_DIR}"
  fi
  systemctl stop fail2ban 2>/dev/null || true
  systemctl disable fail2ban 2>/dev/null || true
  systemctl mask fail2ban 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y fail2ban || true
  apt-get autoremove -y || true
  rm -rf /var/run/fail2ban 2>/dev/null || true
  ok "Fail2Ban остановлен, отключён и удалён."
}

install_crowdsec_repo() {
  log "Подключаю официальный репозиторий CrowdSec..."
  curl -fsSL https://install.crowdsec.net | sh
  apt-get update -y
  ok "Репозиторий CrowdSec подключён."
}

install_crowdsec_agent() {
  log "Устанавливаю CrowdSec agent..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y crowdsec
  systemctl enable crowdsec || true
  ok "CrowdSec установлен."
}

install_collections() {
  log "Устанавливаю базовые collections..."
  cscli collections install crowdsecurity/linux || true
  cscli collections install crowdsecurity/sshd || true
  if [[ "${INSTALL_WEB_COLLECTIONS}" == "yes" ]]; then
    cscli collections install crowdsecurity/nginx || true
    cscli collections install crowdsecurity/apache2 || true
  elif [[ "${INSTALL_WEB_COLLECTIONS}" == "auto" ]]; then
    if command -v nginx >/dev/null 2>&1 || [[ -d /var/log/nginx ]]; then
      log "Обнаружен Nginx. Устанавливаю nginx collection."
      cscli collections install crowdsecurity/nginx || true
    fi
    if command -v apache2 >/dev/null 2>&1 || [[ -d /var/log/apache2 ]]; then
      log "Обнаружен Apache. Устанавливаю apache2 collection."
      cscli collections install crowdsecurity/apache2 || true
    fi
  fi
  ok "Collections установлены или уже были установлены."
}

configure_acquisition() {
  log "Настраиваю источники логов для мониторинга..."
  mkdir -p /etc/crowdsec/acquis.d
  cat > /etc/crowdsec/acquis.d/sshd.yaml <<'YAML'
filenames:
  - /var/log/auth.log
  - /var/log/secure
labels:
  type: syslog
YAML
  if [[ "${INSTALL_WEB_COLLECTIONS}" == "yes" || "${INSTALL_WEB_COLLECTIONS}" == "auto" ]]; then
    if [[ -d /var/log/nginx ]]; then
      cat > /etc/crowdsec/acquis.d/nginx.yaml <<'YAML'
filenames:
  - /var/log/nginx/access.log
  - /var/log/nginx/error.log
labels:
  type: nginx
YAML
      ok "Добавлен мониторинг Nginx logs."
    fi
    if [[ -d /var/log/apache2 ]]; then
      cat > /etc/crowdsec/acquis.d/apache2.yaml <<'YAML'
filenames:
  - /var/log/apache2/access.log
  - /var/log/apache2/error.log
labels:
  type: apache2
YAML
      ok "Добавлен мониторинг Apache logs."
    fi
  fi
  ok "Источники логов настроены."
}

register_to_central_lapi() {
  load_env_if_exists
  log "Регистрирую VPS на центральном LAPI..."
  systemctl stop crowdsec || true
  mkdir -p /etc/crowdsec

  # Critical fix: do not delete local_api_credentials.yaml before registration.
  # Some CrowdSec versions try to read it before writing new credentials.
  if [[ ! -f /etc/crowdsec/local_api_credentials.yaml ]]; then
    cat > /etc/crowdsec/local_api_credentials.yaml <<'YAML'
url: http://127.0.0.1:8080
login: temporary
password: temporary
YAML
  fi

  cp -a /etc/crowdsec/local_api_credentials.yaml "/etc/crowdsec/local_api_credentials.yaml.backup.before-register.$(date +%F-%H%M%S)" || true

  cscli lapi register \
    --machine "${MACHINE_NAME}" \
    --url "${CENTRAL_LAPI_URL}" \
    --token "${AUTO_REG_TOKEN}" \
    --file /etc/crowdsec/local_api_credentials.yaml

  [[ -f /etc/crowdsec/local_api_credentials.yaml ]] || fail "Регистрация не создала /etc/crowdsec/local_api_credentials.yaml"
  ok "VPS зарегистрирован на центральном LAPI."
}

configure_agent_as_node() {
  log "Настраиваю CrowdSec как node, который отправляет события на центральный LAPI..."
  [[ -f /etc/crowdsec/config.yaml ]] || { warn "Не найден /etc/crowdsec/config.yaml, пропускаю."; return; }
  cp -a /etc/crowdsec/config.yaml "/etc/crowdsec/config.yaml.backup.node.$(date +%F-%H%M%S)"
  python3 - <<'PY'
from pathlib import Path
import yaml
path = Path('/etc/crowdsec/config.yaml')
with path.open('r', errors='replace') as f:
    cfg = yaml.safe_load(f) or {}
cfg.setdefault('api', {})
cfg['api'].setdefault('client', {})
cfg['api']['client']['credentials_path'] = '/etc/crowdsec/local_api_credentials.yaml'
server = cfg['api'].get('server')
if isinstance(server, dict) and 'listen_uri' in server:
    server['listen_uri'] = '127.0.0.1:8080'
with path.open('w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
PY
  ok "Конфиг CrowdSec node обновлён."
}

detect_firewall_bouncer_package() {
  FIREWALL_BOUNCER_PACKAGE="crowdsec-firewall-bouncer-iptables"
  FIREWALL_BOUNCER_MODE="iptables"
  if command -v nft >/dev/null 2>&1 && iptables -V 2>/dev/null | grep -qi "nf_tables"; then
    FIREWALL_BOUNCER_PACKAGE="crowdsec-firewall-bouncer-nftables"
    FIREWALL_BOUNCER_MODE="nftables"
  fi
  save_env
}

install_firewall_bouncer() {
  load_env_if_exists
  if [[ "${INSTALL_FIREWALL_BOUNCER}" != "yes" ]]; then
    warn "Firewall bouncer отключён по выбору пользователя."
    return
  fi
  detect_firewall_bouncer_package
  log "Устанавливаю CrowdSec firewall bouncer: ${FIREWALL_BOUNCER_PACKAGE}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${FIREWALL_BOUNCER_PACKAGE}"
  [[ -f /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml ]] || fail "Не найден /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
  cp -a /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml "/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.backup.node.$(date +%F-%H%M%S)"
  cat > /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml <<YAML
mode: ${FIREWALL_BOUNCER_MODE}
piddir: /var/run/
update_frequency: 10s
daemonize: true
log_mode: file
log_dir: /var/log/
log_level: info
api_url: ${CENTRAL_LAPI_URL}
api_key: ${SHARED_BOUNCER_KEY}
disable_ipv6: false
deny_action: DROP
deny_log: false
supported_decisions_types:
  - ban
YAML
  systemctl enable --now crowdsec-firewall-bouncer
  ok "Firewall bouncer установлен и подключён к центральному LAPI."
}

test_config() {
  log "Проверяю конфигурацию CrowdSec..."
  crowdsec -c /etc/crowdsec/config.yaml -t
  ok "Конфигурация CrowdSec корректна."
}

restart_services() {
  log "Перезапускаю сервисы..."
  systemctl reset-failed crowdsec || true
  systemctl restart crowdsec
  if [[ "${INSTALL_FIREWALL_BOUNCER}" == "yes" ]]; then
    systemctl restart crowdsec-firewall-bouncer || true
  fi
  ok "Сервисы перезапущены."
}

show_status() {
  echo
  echo "============================================================"
  echo "ГОТОВО"
  echo "============================================================"
  echo "Активно на этом VPS:"
  echo "  CrowdSec agent: читает логи и отправляет события на центральный LAPI"
  echo "  SSH monitoring: /var/log/auth.log и /var/log/secure, если они есть"
  echo "  Linux collection: базовые Linux-сценарии"
  echo "  SSHD collection: защита SSH"
  if [[ "${INSTALL_WEB_COLLECTIONS}" != "no" ]]; then
    [[ -d /var/log/nginx ]] && echo "  Nginx monitoring: /var/log/nginx/access.log и error.log"
    [[ -d /var/log/apache2 ]] && echo "  Apache monitoring: /var/log/apache2/access.log и error.log"
  fi
  if [[ "${INSTALL_FIREWALL_BOUNCER}" == "yes" ]]; then
    echo "  Firewall bouncer: активная блокировка IP через ${FIREWALL_BOUNCER_MODE}"
  else
    echo "  Firewall bouncer: не установлен"
  fi
  echo "Отключено и удалено: Fail2Ban"
  echo
  echo "Центральный LAPI: ${CENTRAL_LAPI_URL}"
  echo "Machine name: ${MACHINE_NAME}"
  echo "Файл настроек VPS: ${ENV_FILE}"
  echo
  echo "Проверка на VPS:"
  echo "  sudo systemctl status crowdsec --no-pager -l"
  echo "  sudo cscli lapi status"
  echo "  sudo cscli metrics"
  if [[ "${INSTALL_FIREWALL_BOUNCER}" == "yes" ]]; then
    echo "  sudo systemctl status crowdsec-firewall-bouncer --no-pager -l"
    echo "  sudo journalctl -u crowdsec-firewall-bouncer --no-pager -n 80"
  fi
  echo
  echo "Проверка на центральном сервере:"
  echo "  sudo cscli machines list"
  echo "  sudo cscli machines validate ${MACHINE_NAME}   # если auto-registration не провалидировала автоматически"
  echo "  sudo cscli alerts list"
  echo "  sudo cscli decisions list"
  echo
  echo "Резервная копия Fail2Ban, если он был установлен: ${FAIL2BAN_BACKUP_DIR}"
  echo "============================================================"
}

main() {
  require_root
  detect_debian
  require_interactive_install
  bootstrap_installer_tui || true
  ask_settings
  if command -v whiptail >/dev/null 2>&1; then
    tui_theme
    run_install_step "Устанавливаю базовые пакеты" install_base
    run_install_step "Удаляю Fail2Ban при наличии" remove_fail2ban_if_installed
    run_install_step "Подключаю репозиторий CrowdSec" install_crowdsec_repo
    run_install_step "Устанавливаю CrowdSec agent" install_crowdsec_agent
    run_install_step "Устанавливаю collections" install_collections
    run_install_step "Настраиваю источники логов" configure_acquisition
    run_install_step "Регистрирую VPS на центральном LAPI" register_to_central_lapi
    run_install_step "Настраиваю CrowdSec node" configure_agent_as_node
    run_install_step "Устанавливаю firewall bouncer" install_firewall_bouncer
    run_install_step "Проверяю конфигурацию" test_config
    run_install_step "Перезапускаю сервисы" restart_services
  else
    install_base
    remove_fail2ban_if_installed
    install_crowdsec_repo
    install_crowdsec_agent
    install_collections
    configure_acquisition
    register_to_central_lapi
    configure_agent_as_node
    install_firewall_bouncer
    test_config
    restart_services
  fi
  if command -v whiptail >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    show_status >"${tmp}"
    whiptail --title " Установка завершена " --textbox "${tmp}" 30 110 || true
    rm -f "${tmp}"
  else
    show_status
  fi
}

main "$@"
