#!/usr/bin/env bash
set -Eeuo pipefail

# CrowdSec Central LAPI + Web UI + interactive menu for Debian/Ubuntu LXC/VM
# Fixed version based on the full troubleshooting session.
#
# Install:
#   sudo bash install-central-crowdsec-ui-menu-fixed.sh
#
# Menu after install:
#   sudo crowdsec-central-menu
#
# Main fixes included:
# - Never writes empty auto-registration token to CrowdSec config.
# - Sanitizes broken/non-printable ALLOWED_RANGES values.
# - Allows Docker bridge network to reach central LAPI, so Web UI does not show LAPI Offline.
# - Removes CIDR entries by number, not by typing the exact string.
# - Keeps system/Docker/CrowdSec/Web UI update actions in the menu.
# - Installs the menu command by copying this script when available and keeps all functions intact.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_DIR="/root/crowdsec-central"
ENV_FILE="${CONFIG_DIR}/central.env"
COMPOSE_DIR="/opt/crowdsec-web-ui"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
MANAGER_COMPOSE_DIR="/opt/crowdsec-manager"
MANAGER_COMPOSE_FILE="${MANAGER_COMPOSE_DIR}/docker-compose.yml"
INSTALLED_SCRIPT="/usr/local/sbin/crowdsec-central-menu"
PROFILE_FILE="/etc/profile.d/crowdsec-central-menu.sh"
DEFAULT_WEB_PORT="3000"
DEFAULT_LAPI_PORT="8080"
WEBUI_IMAGE="ghcr.io/theduffman85/crowdsec-web-ui:latest"
MANAGER_IMAGE="hhftechnology/crowdsec-manager:independent"
SCRIPT_VERSION="2026.05.22-manager-full-uvar-fix"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/nick2ld/scripts/main/central.sh"

log() { echo -e "${BLUE}==>${NC} $*"; }
ok() { echo -e "${GREEN}OK:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
fail() { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
pause() {
  if [[ "${CROWDSEC_TUI_MODE:-}" != "whiptail" && "${CROWDSEC_TUI_MODE:-}" != "installer" ]]; then
    echo
    read -rp "Нажми Enter для продолжения..." _ || true
  fi
}
is_interactive() { [[ -t 0 ]]; }
has_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }
is_tui_session() { [[ -n "${CROWDSEC_TUI_MODE:-}" && -t 1 && -r /dev/tty ]]; }
require_interactive_install() {
  if ! is_interactive; then
    fail "Интерактивная установка не работает через pipe. Скачай скрипт во временный файл и запусти его: tmp=\"\$(mktemp)\" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/central.sh -o \"\$tmp\" && bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc"
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
is_valid_port() {
  local p="${1:-}"
  [[ "${p}" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

show_output() {
  local title="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}"
  show_file "${title}" "${tmp}"
  rm -f "${tmp}"
}

run_menu_step() {
  local title="$1"
  shift
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    local log_file
    log_file="$(mktemp)"
    whiptail --title " Выполнение " --infobox "${title}...\nПожалуйста, подождите." 8 78
    if "$@" >"${log_file}" 2>&1; then
      rm -f "${log_file}"
      whiptail --title " Успех " --msgbox "${title} успешно завершено." 8 78
      return 0
    else
      whiptail --title " Ошибка " --textbox "${log_file}" 30 110
      rm -f "${log_file}"
      return 1
    fi
  else
    log "${title}..."
    if "$@"; then
      ok "${title} завершено."
      return 0
    else
      warn "${title} заверсилось с ошибкой."
      return 1
    fi
  fi
}

show_file() {
  local title="$1"
  local tmp="$2"
  if is_tui_session; then
    if [[ "${CROWDSEC_TUI_MODE}" =~ ^(whiptail|installer)$ ]] && command -v whiptail >/dev/null 2>&1; then
      whiptail --title " ${title} " --textbox "${tmp}" 30 110 </dev/tty >/dev/tty 2>&1 || true
    elif command -v less >/dev/null 2>&1; then
      clear || true
      LESS='-R' less "${tmp}" </dev/tty >/dev/tty || true
    else
      clear || true
      printf '%s\n\n' "${title}" >/dev/tty
      cat "${tmp}" >/dev/tty
      read -rp "Нажми Enter для продолжения..." _ </dev/tty || true
    fi
  else
    clear || true
    if has_tty; then
      printf '%s\n\n' "${title}" >/dev/tty
      cat "${tmp}" >/dev/tty
      read -rp "Нажми Enter для продолжения..." _ </dev/tty || true
    else
      printf '%s\n\n' "${title}"
      cat "${tmp}"
      pause
    fi
  fi
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Запусти от root: sudo bash $0"
}

detect_debian() {
  [[ -f /etc/debian_version ]] || fail "Это должен быть Debian/Ubuntu/Debian-based контейнер."
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    log "Система: ${PRETTY_NAME:-Debian/Ubuntu}"
  fi
}

get_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

sanitize_ranges() {
  python3 - <<'PY'
import os, re
raw = os.environ.get('RAW_RANGES', '')
items = []
for item in raw.split(','):
    item = ''.join(ch for ch in item.strip() if ch.isprintable())
    item = re.sub(r'[^0-9A-Fa-f:.\/]', '', item)
    if item and item not in items:
        items.append(item)
print(','.join(items))
PY
}

safe_source_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set -u
  fi

  LAN_IP="${LAN_IP:-$(get_lan_ip)}"
  WEB_PORT="${WEB_PORT:-${DEFAULT_WEB_PORT}}"
  LAPI_PORT="${LAPI_PORT:-${DEFAULT_LAPI_PORT}}"
  PUBLIC_ADDR="${PUBLIC_ADDR:-}"
  ALLOWED_RANGES="${ALLOWED_RANGES:-}"
  AUTO_REG_TOKEN="${AUTO_REG_TOKEN:-}"
  SHARED_BOUNCER_KEY="${SHARED_BOUNCER_KEY:-}"
  WEBUI_PASSWORD="${WEBUI_PASSWORD:-}"
  WEB_UI_TYPE="${WEB_UI_TYPE:-simple}"

  if [[ -z "${LAN_IP}" ]]; then
    LAN_IP="127.0.0.1"
  fi

  RAW_RANGES="${ALLOWED_RANGES}" ALLOWED_RANGES="$(RAW_RANGES="${ALLOWED_RANGES}" sanitize_ranges)"

  LOCAL_WEB_UI="http://${LAN_IP}:${WEB_PORT}"
  LOCAL_LAPI_URL="http://${LAN_IP}:${LAPI_PORT}"
  if [[ -n "${PUBLIC_ADDR}" ]]; then
    VPS_LAPI_URL="http://${PUBLIC_ADDR}:${LAPI_PORT}"
  else
    VPS_LAPI_URL="http://YOUR_PUBLIC_IP_OR_DDNS:${LAPI_PORT}"
  fi
}

save_env() {
  LAN_IP="${LAN_IP:-$(get_lan_ip)}"
  [[ -n "${LAN_IP:-}" ]] || LAN_IP="127.0.0.1"
  WEB_PORT="${WEB_PORT:-${DEFAULT_WEB_PORT}}"
  LAPI_PORT="${LAPI_PORT:-${DEFAULT_LAPI_PORT}}"
  PUBLIC_ADDR="${PUBLIC_ADDR:-}"
  ALLOWED_RANGES="${ALLOWED_RANGES:-}"
  AUTO_REG_TOKEN="${AUTO_REG_TOKEN:-}"
  SHARED_BOUNCER_KEY="${SHARED_BOUNCER_KEY:-}"
  WEBUI_PASSWORD="${WEBUI_PASSWORD:-}"
  WEB_UI_TYPE="${WEB_UI_TYPE:-simple}"

  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"

  [[ -n "${AUTO_REG_TOKEN:-}" ]] || AUTO_REG_TOKEN="$(openssl rand -hex 32)"
  [[ -n "${SHARED_BOUNCER_KEY:-}" ]] || SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"
  [[ -n "${WEBUI_PASSWORD:-}" ]] || WEBUI_PASSWORD="$(openssl rand -hex 24)"

  RAW_RANGES="${ALLOWED_RANGES:-}" ALLOWED_RANGES="$(RAW_RANGES="${ALLOWED_RANGES:-}" sanitize_ranges)"

  LOCAL_WEB_UI="http://${LAN_IP}:${WEB_PORT}"
  LOCAL_LAPI_URL="http://${LAN_IP}:${LAPI_PORT}"
  if [[ -n "${PUBLIC_ADDR:-}" ]]; then
    VPS_LAPI_URL="http://${PUBLIC_ADDR}:${LAPI_PORT}"
  else
    VPS_LAPI_URL="http://YOUR_PUBLIC_IP_OR_DDNS:${LAPI_PORT}"
  fi

  cat > "${ENV_FILE}" <<ENV
LAN_IP=${LAN_IP}
WEB_PORT=${WEB_PORT}
LAPI_PORT=${LAPI_PORT}
LOCAL_WEB_UI=${LOCAL_WEB_UI}
LOCAL_LAPI_URL=${LOCAL_LAPI_URL}
VPS_LAPI_URL=${VPS_LAPI_URL}
PUBLIC_ADDR=${PUBLIC_ADDR}
AUTO_REG_TOKEN=${AUTO_REG_TOKEN}
SHARED_BOUNCER_KEY=${SHARED_BOUNCER_KEY}
ALLOWED_RANGES=${ALLOWED_RANGES}
WEBUI_PASSWORD=${WEBUI_PASSWORD}
WEB_UI_TYPE=${WEB_UI_TYPE}
ENV
  chmod 600 "${ENV_FILE}"
}

print_header() {
  clear || true
  echo "============================================================"
  echo "CrowdSec Central LAPI + Web UI (${SCRIPT_VERSION})"
  echo "============================================================"
  echo
}

print_current_settings() {
  safe_source_env
  echo "Текущие настройки:"
  echo
  echo "Веб-морда:"
  echo "  ${LOCAL_WEB_UI}"
  echo
  echo "Локальный LAPI:"
  echo "  ${LOCAL_LAPI_URL}"
  echo
  echo "LAPI для удалённых серверов:"
  echo "  ${VPS_LAPI_URL}"
  echo
  echo "Allowed IP/CIDR для доступа к LAPI:"
  if [[ -n "${ALLOWED_RANGES}" ]]; then
    echo "  ${ALLOWED_RANGES}"
  else
    echo "  пока не заданы"
  fi
  echo
  echo "Файл настроек:"
  echo "  ${ENV_FILE}"
  echo
}

upgrade_system_packages() {
  log "Обновляю системные пакеты Debian/Ubuntu..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
  apt-get autoremove -y
  apt-get autoclean -y
  ok "Системные пакеты обновлены."
}

install_base() {
  log "Устанавливаю базовые пакеты..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg lsb-release apt-transport-https openssl python3 python3-yaml sudo ufw nano jq iproute2 procps xz-utils whiptail less
  ok "Базовые пакеты установлены."
}

install_or_update_docker_repo() {
  log "Проверяю репозиторий Docker..."
  install -m 0755 -d /etc/apt/keyrings
  rm -f /etc/apt/keyrings/docker.gpg
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091
  source /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  ok "Репозиторий Docker готов."
}

install_or_update_docker() {
  if [[ -f /etc/os-release ]]; then
    # Docker official repo is Debian-specific here. Debian LXC is the target.
    install_or_update_docker_repo
  fi
  log "Устанавливаю или обновляю Docker..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker установлен или обновлён."
}

install_or_update_crowdsec_repo() {
  log "Проверяю репозиторий CrowdSec..."
  curl -fsSL https://install.crowdsec.net | sh
  apt-get update -y
  ok "Репозиторий CrowdSec готов."
}

install_or_update_crowdsec() {
  install_or_update_crowdsec_repo
  log "Устанавливаю или обновляю CrowdSec..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y crowdsec
  systemctl enable --now crowdsec || true
  ok "CrowdSec установлен или обновлён."
}

ask_initial_settings() {
  safe_source_env
  echo
  echo "Начальная настройка. Все параметры можно изменить потом через меню."
  echo "Если не знаешь, что вводить, просто нажимай Enter."
  echo
  DETECTED_IP="$(get_lan_ip)"
  [[ -n "${DETECTED_IP}" ]] || DETECTED_IP="${LAN_IP}"
  echo "LAN IP контейнера определён как: ${DETECTED_IP}"
  prompt_default input_lan_ip "LAN IP для веб-морды и локального LAPI [${DETECTED_IP}]: " "${DETECTED_IP}"
  LAN_IP="${input_lan_ip}"
  prompt_default input_web_port "Порт веб-морды [${WEB_PORT:-3000}]: " "${WEB_PORT:-3000}"
  WEB_PORT="${input_web_port}"
  prompt_default input_lapi_port "Порт центрального LAPI [${LAPI_PORT:-8080}]: " "${LAPI_PORT:-8080}"
  LAPI_PORT="${input_lapi_port}"
  echo
  echo "Allowed IP/CIDR можно оставить пустым и добавить позже через меню."
  echo "Примеры: 11.22.33.44/32 или 11.22.33.44/32,192.168.1.0/24"
  prompt_default input_allowed "Allowed IP/CIDR для LAPI [можно пусто]: " "${ALLOWED_RANGES:-}"
  ALLOWED_RANGES="${input_allowed:-${ALLOWED_RANGES:-}}"
  echo
  echo "Внешний адрес нужен для готовой команды подключения VPS. Можно оставить пустым."
  prompt_default input_public "Внешний адрес для удалённых серверов [можно пусто]: " "${PUBLIC_ADDR:-}"
  PUBLIC_ADDR="${input_public:-${PUBLIC_ADDR:-}}"
  prompt_default input_webui_type "Веб-морда: simple, manager или none [${WEB_UI_TYPE:-simple}]: " "${WEB_UI_TYPE:-simple}"
  WEB_UI_TYPE="${input_webui_type:-simple}"
  [[ -n "${AUTO_REG_TOKEN:-}" ]] || AUTO_REG_TOKEN="$(openssl rand -hex 32)"
  [[ -n "${SHARED_BOUNCER_KEY:-}" ]] || SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"
  [[ -n "${WEBUI_PASSWORD:-}" ]] || WEBUI_PASSWORD="$(openssl rand -hex 24)"
  save_env
}

bootstrap_installer_tui() {
  command -v whiptail >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || return 1
  clear || true
  echo "Подготовка интерактивного установщика..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/tmp/crowdsec-menu-bootstrap.log 2>&1 || return 1
  apt-get install -y whiptail >>/tmp/crowdsec-menu-bootstrap.log 2>&1 || return 1
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

ask_initial_settings_tui() {
  safe_source_env
  DETECTED_IP="$(get_lan_ip)"
  [[ -n "${DETECTED_IP}" ]] || DETECTED_IP="${LAN_IP}"

  LAN_IP="$(tui_input "Начальная настройка" "LAN IP для Web UI и локального LAPI" "${DETECTED_IP}")" || exit 1
  WEB_PORT="$(tui_input "Начальная настройка" "Порт Web UI" "${WEB_PORT:-3000}")" || exit 1
  LAPI_PORT="$(tui_input "Начальная настройка" "Порт центрального LAPI" "${LAPI_PORT:-8080}")" || exit 1
  ALLOWED_RANGES="$(tui_input "Доступ к LAPI" "Allowed IP/CIDR для LAPI. Можно оставить пустым." "${ALLOWED_RANGES:-}")" || exit 1
  PUBLIC_ADDR="$(tui_input "Внешний адрес" "Внешний IP или DDNS для готовой команды подключения VPS. Можно оставить пустым." "${PUBLIC_ADDR:-}")" || exit 1
  WEB_UI_TYPE="$(whiptail --title " Веб-морда " --cancel-button "Отмена" --ok-button "Выбрать" --notags --menu "Что установить на central-сервер?" 16 78 4 \
    "simple" "Simple Web UI (лёгкая локальная веб-морда)" \
    "manager" "CrowdSec Manager (Dockerized CrowdSec + Manager)" \
    "none" "Без веб-морды" \
    3>&1 1>&2 2>&3)" || exit 1

  [[ -n "${AUTO_REG_TOKEN:-}" ]] || AUTO_REG_TOKEN="$(openssl rand -hex 32)"
  [[ -n "${SHARED_BOUNCER_KEY:-}" ]] || SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"
  [[ -n "${WEBUI_PASSWORD:-}" ]] || WEBUI_PASSWORD="$(openssl rand -hex 24)"
  save_env
}

configure_crowdsec_lapi() {
  safe_source_env
  if [[ -z "${AUTO_REG_TOKEN:-}" ]]; then
    AUTO_REG_TOKEN="$(openssl rand -hex 32)"
    save_env
  fi

  log "Настраиваю CrowdSec LAPI на 0.0.0.0:${LAPI_PORT}..."
  [[ -f /etc/crowdsec/config.yaml ]] || fail "Не найден /etc/crowdsec/config.yaml"
  cp -a /etc/crowdsec/config.yaml "/etc/crowdsec/config.yaml.backup.$(date +%F-%H%M%S)"

  AUTO_REG_TOKEN="${AUTO_REG_TOKEN}" ALLOWED_RANGES="${ALLOWED_RANGES}" LAPI_PORT="${LAPI_PORT}" python3 - <<'PY'
import os, yaml, re
path = "/etc/crowdsec/config.yaml"
token = os.environ.get("AUTO_REG_TOKEN", "").strip()
if not token:
    raise SystemExit("AUTO_REG_TOKEN is empty, refusing to write broken CrowdSec config")
with open(path, "r", errors="replace") as f:
    cfg = yaml.safe_load(f) or {}
cfg.setdefault("api", {})
cfg["api"].setdefault("server", {})
cfg["api"]["server"]["listen_uri"] = f"0.0.0.0:{os.environ.get('LAPI_PORT', '8080')}"
ranges = []
for item in os.environ.get("ALLOWED_RANGES", "").split(','):
    item = ''.join(ch for ch in item.strip() if ch.isprintable())
    item = re.sub(r'[^0-9A-Fa-f:.\/]', '', item)
    if item and item not in ranges:
        ranges.append(item)
cfg["api"]["server"]["auto_registration"] = {
    "enabled": True,
    "token": token,
    "allowed_ranges": ranges,
}
with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
PY

  crowdsec -c /etc/crowdsec/config.yaml -t
  systemctl reset-failed crowdsec || true
  systemctl restart crowdsec
  ok "CrowdSec LAPI настроен."
}

create_or_update_webui_machine() {
  safe_source_env
  [[ -n "${WEBUI_PASSWORD:-}" ]] || WEBUI_PASSWORD="$(openssl rand -hex 24)"
  save_env
  log "Создаю или обновляю machine account для веб-морды..."
  cscli machines add crowdsec-web-ui --password "${WEBUI_PASSWORD}" --force --file /tmp/crowdsec-web-ui-creds.yaml >/dev/null || true
  rm -f /tmp/crowdsec-web-ui-creds.yaml
  systemctl restart crowdsec || true
  ok "Machine account для веб-морды готов."
}

create_or_update_shared_bouncer_key() {
  safe_source_env
  [[ -n "${SHARED_BOUNCER_KEY:-}" ]] || SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"
  save_env
  if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
    if docker exec crowdsec cscli bouncers list 2>/dev/null | grep -q "shared-firewall-bouncer"; then
      ok "Bouncer shared-firewall-bouncer уже существует в Docker."
      return
    fi
    log "Создаю общий bouncer key для удалённых серверов в Docker..."
    docker exec crowdsec cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null || true
  else
    if cscli bouncers list 2>/dev/null | grep -q "shared-firewall-bouncer"; then
      ok "Bouncer shared-firewall-bouncer уже существует."
      return
    fi
    log "Создаю общий bouncer key для удалённых серверов..."
    cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null || true
  fi
  ok "Bouncer key готов."
}

backup_and_remove_apt_crowdsec() {
  local backup_dir="${CONFIG_DIR}/backup-before-docker-crowdsec-$(date +%F-%H%M%S)"
  mkdir -p "${backup_dir}"
  chmod 700 "${backup_dir}"
  log "Создаю backup текущего apt/systemd CrowdSec в ${backup_dir}"
  [[ -d /etc/crowdsec ]] && cp -a /etc/crowdsec "${backup_dir}/etc-crowdsec" || true
  [[ -d /var/lib/crowdsec ]] && cp -a /var/lib/crowdsec "${backup_dir}/var-lib-crowdsec" || true
  systemctl stop crowdsec 2>/dev/null || true
  systemctl disable crowdsec 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y crowdsec || true
  apt-get autoremove -y || true
  ok "apt/systemd CrowdSec остановлен, удалён, backup сохранён."
}

remove_crowdsec_manager() {
  if [[ -f "${MANAGER_COMPOSE_FILE}" ]]; then
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose down --remove-orphans) || true
  else
    docker rm -f crowdsec-manager crowdsec >/dev/null 2>&1 || true
  fi
}

remove_all_web_ui_containers() {
  if [[ -f "${COMPOSE_FILE}" ]]; then
    (cd "${COMPOSE_DIR}" && docker compose down --remove-orphans) || true
  else
    docker rm -f crowdsec-web-ui >/dev/null 2>&1 || true
  fi
  rm -rf "${COMPOSE_DIR}"
  remove_crowdsec_manager
}

configure_docker_crowdsec_lapi() {
  local config_file="${MANAGER_COMPOSE_DIR}/crowdsec-config/config.yaml"
  [[ -f "${config_file}" ]] || fail "Не найден ${config_file}"
  AUTO_REG_TOKEN="${AUTO_REG_TOKEN}" ALLOWED_RANGES="${ALLOWED_RANGES}" python3 - "${config_file}" <<'PY'
import os, re, sys, yaml
path = sys.argv[1]
with open(path, "r", errors="replace") as f:
    cfg = yaml.safe_load(f) or {}
cfg.setdefault("api", {})
cfg["api"].setdefault("server", {})
cfg["api"]["server"]["listen_uri"] = "0.0.0.0:8080"
ranges = []
for item in os.environ.get("ALLOWED_RANGES", "").split(","):
    item = re.sub(r"[^0-9A-Fa-f:.\/]", "", item.strip())
    if item and item not in ranges:
        ranges.append(item)
cfg["api"]["server"]["auto_registration"] = {
    "enabled": True,
    "token": os.environ["AUTO_REG_TOKEN"],
    "allowed_ranges": ranges,
}
with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
PY
}

install_or_update_crowdsec_manager() {
  safe_source_env
  [[ "${WEB_PORT}" != "${LAPI_PORT}" ]] || fail "Для CrowdSec Manager WEB_PORT и LAPI_PORT должны быть разными."
  log "Устанавливаю CrowdSec Manager + Dockerized CrowdSec..."
  remove_all_web_ui_containers
  backup_and_remove_apt_crowdsec
  mkdir -p "${MANAGER_COMPOSE_DIR}/config" "${MANAGER_COMPOSE_DIR}/logs/app" "${MANAGER_COMPOSE_DIR}/data" "${MANAGER_COMPOSE_DIR}/backups" "${MANAGER_COMPOSE_DIR}/crowdsec-config" "${MANAGER_COMPOSE_DIR}/crowdsec-db" "${MANAGER_COMPOSE_DIR}/logs/host"
  chmod 700 "${MANAGER_COMPOSE_DIR}"
  cat > "${MANAGER_COMPOSE_FILE}" <<COMPOSE
services:
  crowdsec-manager:
    image: ${MANAGER_IMAGE}
    container_name: crowdsec-manager
    restart: unless-stopped
    ports:
      - "${LAN_IP}:${WEB_PORT}:8080"
    environment:
      - PORT=8080
      - ENVIRONMENT=production
      - CONFIG_DIR=/app/config
      - DATABASE_PATH=/app/data/settings.db
      - BACKUP_DIR=/app/backups
      - INCLUDE_CROWDSEC=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./config:/app/config
      - ./logs/app:/app/logs
      - ./data:/app/data
      - ./backups:/app/backups
    networks:
      - crowdsec-network
    depends_on:
      - crowdsec

  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: unless-stopped
    environment:
      - COLLECTIONS=crowdsecurity/linux crowdsecurity/sshd
      - GID=1000
    ports:
      - "0.0.0.0:${LAPI_PORT}:8080"
    volumes:
      - ./crowdsec-db:/var/lib/crowdsec/data
      - ./crowdsec-config:/etc/crowdsec
      - /var/log:/var/log:ro
    networks:
      - crowdsec-network

networks:
  crowdsec-network:
    driver: bridge
COMPOSE
  (cd "${MANAGER_COMPOSE_DIR}" && docker compose pull && docker compose up -d)
  sleep 8
  configure_docker_crowdsec_lapi
  (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)
  sleep 5
  docker exec crowdsec cscli bouncers delete shared-firewall-bouncer >/dev/null 2>&1 || true
  docker exec crowdsec cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null || true
  WEB_UI_TYPE="manager"
  save_env
  ok "CrowdSec Manager установлен. UI: http://${LAN_IP}:${WEB_PORT}, LAPI: ${VPS_LAPI_URL}"
}

install_or_update_web_ui() {
  safe_source_env
  log "Поднимаю или обновляю веб-морду на ${LAN_IP}:${WEB_PORT}..."
  mkdir -p "${COMPOSE_DIR}/data"
  chmod 700 "${COMPOSE_DIR}"
  cat > "${COMPOSE_FILE}" <<COMPOSE
services:
  crowdsec-web-ui:
    image: ${WEBUI_IMAGE}
    container_name: crowdsec-web-ui
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      CROWDSEC_URL: "http://host.docker.internal:${LAPI_PORT}"
      CROWDSEC_USER: "crowdsec-web-ui"
      CROWDSEC_PASSWORD: "${WEBUI_PASSWORD}"
      CROWDSEC_LOOKBACK_PERIOD: "30d"
      CROWDSEC_REFRESH_INTERVAL: "30s"
    ports:
      - "${LAN_IP}:${WEB_PORT}:3000"
    volumes:
      - ./data:/app/data
COMPOSE
  cd "${COMPOSE_DIR}"
  docker compose pull || true
  docker compose up -d
  ok "Веб-морда запущена или обновлена."
}

configure_ufw_full() {
  safe_source_env
  log "Настраиваю firewall через ufw..."
  warn "Этот скрипт управляет ufw внутри контейнера и пересоздаёт правила."
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh || true

  # Web UI only from private networks.
  ufw allow from 10.0.0.0/8 to any port "${WEB_PORT}" proto tcp
  ufw allow from 172.16.0.0/12 to any port "${WEB_PORT}" proto tcp
  ufw allow from 192.168.0.0/16 to any port "${WEB_PORT}" proto tcp

  # Critical fix: Docker bridge network must reach central LAPI, otherwise Web UI shows LAPI Offline.
  ufw allow from 172.16.0.0/12 to any port "${LAPI_PORT}" proto tcp

  # Remote VPS nodes allowed to central LAPI.
  if [[ -n "${ALLOWED_RANGES}" ]]; then
    IFS=',' read -ra ranges <<< "${ALLOWED_RANGES}"
    for range in "${ranges[@]}"; do
      range="$(echo "${range}" | xargs)"
      [[ -n "${range}" ]] || continue
      ufw allow from "${range}" to any port "${LAPI_PORT}" proto tcp
    done
  fi
  ufw --force enable
  ok "Firewall настроен."
}

find_this_script() {
  local src=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    src="${BASH_SOURCE[0]}"
  elif [[ -f "$0" ]]; then
    src="$0"
  elif [[ -f ./install-central-crowdsec-ui-menu-fixed.sh ]]; then
    src="./install-central-crowdsec-ui-menu-fixed.sh"
  elif [[ -f /root/install-central-crowdsec-ui-menu-fixed.sh ]]; then
    src="/root/install-central-crowdsec-ui-menu-fixed.sh"
  elif [[ -f /root/install-central-crowdsec-ui-menu.sh ]]; then
    src="/root/install-central-crowdsec-ui-menu.sh"
  fi
  if [[ -n "${src}" ]]; then
    readlink -f "${src}"
  fi
}

install_menu_files() {
  log "Устанавливаю интерактивное меню..."
  local src
  src="$(find_this_script || true)"
  if [[ -n "${src}" && -f "${src}" ]]; then
    install -m 0755 "${src}" "${INSTALLED_SCRIPT}"
    ok "Меню установлено в ${INSTALLED_SCRIPT}"
  else
    fail "Не удалось определить путь к скрипту. Сохрани файл на диск и запусти: sudo bash /root/install-central-crowdsec-ui-menu-fixed.sh"
  fi

  cat > "${PROFILE_FILE}" <<'PROFILE'
# CrowdSec Central menu autostart for root interactive login shells
if [ "$(id -u)" = "0" ] && [ -t 1 ]; then
  if [ -x /usr/local/sbin/crowdsec-central-menu ]; then
    if [ -z "${CROWDSEC_MENU_SHOWN:-}" ]; then
      export CROWDSEC_MENU_SHOWN=1
      echo
      echo "CrowdSec Central menu доступно командой: crowdsec-central-menu"
      echo "Открыть меню сейчас?"
      printf "Enter - открыть, n - пропустить: "
      read ans
      case "$ans" in
        n|N|no|NO|No) ;;
        *) /usr/local/sbin/crowdsec-central-menu --menu ;;
      esac
    fi
  fi
fi
PROFILE
  chmod 644 "${PROFILE_FILE}"
  ok "Автозапуск меню при входе настроен."
}

update_menu_from_github() {
  require_root
  log "Скачиваю актуальную версию меню из GitHub..."
  command -v curl >/dev/null 2>&1 || fail "Не найден curl. Установи: apt-get update && apt-get install -y curl"
  local tmp
  tmp="$(mktemp)"
  curl -fsSL -H "Cache-Control: no-cache" "${SCRIPT_RAW_URL}?$(date +%s)" -o "${tmp}"
  bash -n "${tmp}"
  install -m 0755 "${tmp}" "${INSTALLED_SCRIPT}"
  rm -f "${tmp}"
  ok "Меню обновлено: ${INSTALLED_SCRIPT}"
}

run_install_step() {
  local title="$1"
  shift
  local log_file
  log_file="$(mktemp)"
  if [[ "${CROWDSEC_TUI_MODE:-}" == "installer" ]] && command -v whiptail >/dev/null 2>&1; then
    whiptail --title " Установка " --infobox "${title}\n\nПодробный лог пишется во временный файл." 9 72 || true
  else
    print_header
    log "${title}"
  fi

  if "$@" >"${log_file}" 2>&1; then
    rm -f "${log_file}"
    return 0
  fi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "installer" ]] && command -v whiptail >/dev/null 2>&1; then
    whiptail --title " Ошибка: ${title} " --textbox "${log_file}" 30 110 || true
  else
    cat "${log_file}"
  fi
  rm -f "${log_file}"
  fail "Этап установки завершился ошибкой: ${title}"
}

show_install_result() {
  safe_source_env
  echo
  echo "============================================================"
  echo "ГОТОВО"
  echo "============================================================"
  echo "Веб-морда: ${LOCAL_WEB_UI}"
  echo "Центральный LAPI локально: ${LOCAL_LAPI_URL}"
  echo "Центральный LAPI для VPS: ${VPS_LAPI_URL}"
  echo "Файл настроек и токенов: ${ENV_FILE}"
  echo "Открыть меню: sudo crowdsec-central-menu"
  echo "Проброс на роутере, если LAPI должен быть доступен VPS: WAN TCP ${LAPI_PORT} -> ${LAN_IP}:${LAPI_PORT}"
  echo "Не пробрасывать наружу: WAN TCP ${WEB_PORT}"
  echo "============================================================"
}

show_install_result_tui() {
  {
    show_install_result
  } | show_output "Установка завершена"
}

full_install() {
  require_root
  detect_debian
  require_interactive_install
  if bootstrap_installer_tui; then
    export CROWDSEC_TUI_MODE="installer"
    tui_theme
    whiptail --title " CrowdSec Central " --msgbox "Установка CrowdSec Central LAPI + Web UI.\n\nВсе параметры можно будет изменить позже через меню." 12 78
    if tui_yesno "Обновление системы" "Перед установкой обновить системные пакеты Debian?"; then
      do_upgrade="Y"
    else
      do_upgrade="N"
    fi
    ask_initial_settings_tui
    run_install_step "Устанавливаю базовые пакеты" install_base
    if [[ ! "${do_upgrade:-Y}" =~ ^[Nn]$ ]]; then
      run_install_step "Обновляю системные пакеты Debian" upgrade_system_packages
    fi
    run_install_step "Устанавливаю или обновляю Docker" install_or_update_docker
    if [[ "${WEB_UI_TYPE}" == "manager" ]]; then
      run_install_step "Устанавливаю CrowdSec Manager + Dockerized CrowdSec" install_or_update_crowdsec_manager
    else
      run_install_step "Устанавливаю или обновляю CrowdSec" install_or_update_crowdsec
      run_install_step "Настраиваю CrowdSec LAPI" configure_crowdsec_lapi
      run_install_step "Создаю machine account для Web UI" create_or_update_webui_machine
      run_install_step "Создаю shared bouncer key" create_or_update_shared_bouncer_key
      if [[ "${WEB_UI_TYPE}" == "simple" ]]; then
        run_install_step "Запускаю Web UI" install_or_update_web_ui
      fi
    fi
    run_install_step "Настраиваю UFW firewall" configure_ufw_full
    run_install_step "Устанавливаю команду меню" install_menu_files
    show_install_result_tui
    return
  fi

  print_header
  echo "Установка CrowdSec Central LAPI + Web UI + меню управления."
  echo "Необязательные параметры можно пропустить и изменить позже."
  echo
  prompt_default do_upgrade "Перед установкой обновить системные пакеты Debian? [Y/n]: " "Y"
  ask_initial_settings
  install_base
  if [[ ! "${do_upgrade:-Y}" =~ ^[Nn]$ ]]; then
    upgrade_system_packages
  fi
  install_or_update_docker
  if [[ "${WEB_UI_TYPE}" == "manager" ]]; then
    install_or_update_crowdsec_manager
  else
    install_or_update_crowdsec
    configure_crowdsec_lapi
    create_or_update_webui_machine
    create_or_update_shared_bouncer_key
    [[ "${WEB_UI_TYPE}" == "simple" ]] && install_or_update_web_ui
  fi
  configure_ufw_full
  install_menu_files
  show_install_result
}

show_status() {
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    safe_source_env
    print_current_settings
    echo "Статус сервисов:"
    if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
      docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^crowdsec$' && echo "  CrowdSec Docker: работает" || echo "  CrowdSec Docker: не работает"
      docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^crowdsec-manager$' && echo "  CrowdSec Manager: работает" || echo "  CrowdSec Manager: не работает"
    else
      systemctl is-active --quiet crowdsec && echo "  CrowdSec: работает" || echo "  CrowdSec: не работает"
    fi
    command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker && echo "  Docker: работает" || echo "  Docker: не работает или не установлен"
    if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
      docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^crowdsec-manager$' && echo "  Веб-морда: CrowdSec Manager работает" || echo "  Веб-морда: CrowdSec Manager не работает"
    elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q '^crowdsec-web-ui$'; then
      echo "  Веб-морда: Simple Web UI работает"
    else
      echo "  Веб-морда: не работает"
    fi
    echo
    echo "Порты:"
    ss -lntp 2>/dev/null | grep -E ":(${WEB_PORT}|${LAPI_PORT})" || echo "  порты ${WEB_PORT}/${LAPI_PORT} не найдены в listen"
  } >"${tmp}"
  show_file "Статус" "${tmp}"
  rm -f "${tmp}"
}

show_connection_info() {
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    safe_source_env
    echo "Данные для подключения удалённых серверов:"
    echo "LAPI URL: ${VPS_LAPI_URL}"
    echo "Auto-registration token: ${AUTO_REG_TOKEN}"
    echo "Shared bouncer key: ${SHARED_BOUNCER_KEY}"
    echo "Allowed IP/CIDR: ${ALLOWED_RANGES:-не заданы}"
    echo "Веб-морду наружу не пробрасывать: ${LOCAL_WEB_UI}"
  } >"${tmp}"
  show_file "Данные подключения" "${tmp}"
  rm -f "${tmp}"
}

show_tokens_file() {
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    [[ -f "${ENV_FILE}" ]] && cat "${ENV_FILE}" || echo "Файл настроек не найден: ${ENV_FILE}"
  } >"${tmp}"
  show_file "central.env" "${tmp}"
  rm -f "${tmp}"
}

add_allowed_range() {
  safe_source_env
  local new_range
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    new_range=$(whiptail --title " Добавление IP/CIDR " --inputbox "Введите IP/CIDR для добавления к LAPI (например, 11.22.33.44/32):" 10 78 3>&1 1>&2 2>&3) || return
  else
    print_header
    echo "Добавление IP/CIDR для доступа к LAPI. Пример: 11.22.33.44/32"
    read -rp "Введи IP/CIDR: " new_range
  fi

  new_range="$(printf '%s' "${new_range}" | tr -cd '0-9A-Za-z.:/_-')"
  if [[ -z "${new_range}" ]]; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
      whiptail --title " Ошибка " --msgbox "IP/CIDR не может быть пустым." 8 78
    else
      warn "Пусто. Ничего не добавлено."
      pause
    fi
    return
  fi

  if [[ ! "${new_range}" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]]; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
      whiptail --title " Предупреждение " --yes-button "Добавить" --no-button "Отмена" --yesno "Похоже, это не CIDR.\nВсё равно добавить?" 10 78 || return
    else
      warn "Похоже, это не CIDR."
      read -rp "Всё равно добавить? [y/N]: " confirm
      [[ "${confirm:-N}" =~ ^[Yy]$ ]] || { echo "Отменено."; pause; return; }
    fi
  fi

  if [[ -z "${ALLOWED_RANGES}" ]]; then
    ALLOWED_RANGES="${new_range}"
  else
    if echo ",${ALLOWED_RANGES}," | grep -q ",${new_range},"; then
      if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
        whiptail --title " Ошибка " --msgbox "Этот IP/CIDR уже есть в списке." 8 78
      else
        warn "Этот IP/CIDR уже есть."
        pause
      fi
      return
    fi
    ALLOWED_RANGES="${ALLOWED_RANGES},${new_range}"
  fi

  save_env
  configure_crowdsec_lapi
  configure_ufw_full

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Успех " --msgbox "IP/CIDR добавлен: ${new_range}" 8 78
  else
    ok "IP/CIDR добавлен: ${new_range}"
    pause
  fi
}

remove_allowed_range() {
  safe_source_env
  if [[ -z "${ALLOWED_RANGES}" ]]; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
      whiptail --title " Удаление IP/CIDR " --msgbox "Список Allowed IP/CIDR пуст." 8 78
    else
      echo "Список Allowed IP/CIDR пуст."
      pause
    fi
    return
  fi

  local remove_num
  IFS=',' read -ra items <<< "${ALLOWED_RANGES}"

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    local menu_args=()
    for i in "${!items[@]}"; do
      menu_args+=("$((i+1))" "${items[$i]}")
    done
    remove_num=$(whiptail --title " Удаление IP/CIDR " --cancel-button "Отмена" --ok-button "Удалить" --menu "Выберите пункт для удаления:" 18 78 8 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return
  else
    print_header
    echo "Удаление IP/CIDR по номеру:"
    for i in "${!items[@]}"; do echo "$((i+1)) - ${items[$i]}"; done
    echo
    read -rp "Введи номер пункта для удаления или Enter для отмены: " remove_num
    [[ -n "${remove_num}" ]] || { echo "Отменено."; pause; return; }
    [[ "${remove_num}" =~ ^[0-9]+$ ]] || { warn "Нужно ввести номер."; pause; return; }
    if (( remove_num < 1 || remove_num > ${#items[@]} )); then
      warn "Номер вне диапазона."
      pause
      return
    fi
  fi

  local new_list=""
  for i in "${!items[@]}"; do
    if [[ $((i+1)) -ne ${remove_num} ]]; then
      item="$(echo "${items[$i]}" | xargs)"
      [[ -n "${item}" ]] || continue
      [[ -z "${new_list}" ]] && new_list="${item}" || new_list="${new_list},${item}"
    fi
  done
  ALLOWED_RANGES="${new_list}"
  save_env
  configure_crowdsec_lapi
  configure_ufw_full

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Успех " --msgbox "Пункт удалён." 8 78
  else
    ok "Пункт удалён."
    pause
  fi
}

replace_allowed_ranges() {
  safe_source_env
  local new_ranges
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    new_ranges=$(whiptail --title " Замена списка IP/CIDR " --inputbox "Текущий список: ${ALLOWED_RANGES:-пуст}\n\nВведите новый список через запятую:" 12 78 "${ALLOWED_RANGES}" 3>&1 1>&2 2>&3) || return
  else
    print_header
    echo "Сейчас: ${ALLOWED_RANGES:-список пуст}"
    echo "Введи новый список через запятую. Пусто закроет LAPI для удалённых IP."
    read -rp "Новый Allowed IP/CIDR: " new_ranges
  fi

  ALLOWED_RANGES="${new_ranges:-}"
  save_env
  configure_crowdsec_lapi
  configure_ufw_full

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Успех " --msgbox "Список Allowed IP/CIDR обновлён." 8 78
  else
    ok "Список Allowed IP/CIDR обновлён."
    pause
  fi
}

change_lan_ip_or_web_port() {
  safe_source_env
  local new_lan_ip new_web_port
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    new_lan_ip=$(whiptail --title " Изменение LAN IP " --inputbox "Введите новый LAN IP:" 10 78 "${LAN_IP}" 3>&1 1>&2 2>&3) || return
    new_web_port=$(whiptail --title " Изменение порта Web UI " --inputbox "Введите новый порт веб-морды:" 10 78 "${WEB_PORT}" 3>&1 1>&2 2>&3) || return
  else
    print_header
    echo "Сейчас: LAN IP ${LAN_IP}, Web port ${WEB_PORT}, Web UI ${LOCAL_WEB_UI}"
    read -rp "Новый LAN IP [${LAN_IP}]: " new_lan_ip
    read -rp "Новый порт веб-морды [${WEB_PORT}]: " new_web_port
  fi

  if [[ -n "${new_web_port}" ]] && ! is_valid_port "${new_web_port}"; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
      whiptail --title " Ошибка " --msgbox "Некорректный порт: ${new_web_port}" 8 78
    else
      warn "Некорректный порт: ${new_web_port}"
      pause
    fi
    return
  fi

  LAN_IP="${new_lan_ip:-${LAN_IP}}"
  WEB_PORT="${new_web_port:-${WEB_PORT}}"
  save_env
  install_or_update_web_ui
  configure_ufw_full

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Успех " --msgbox "Адрес веб-морды обновлён: ${LOCAL_WEB_UI}" 8 78
  else
    ok "Адрес веб-морды обновлён: ${LOCAL_WEB_UI}"
    pause
  fi
}

change_lapi_port() {
  safe_source_env
  local new_lapi_port
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    new_lapi_port=$(whiptail --title " Изменение порта LAPI " --inputbox "Введите новый порт LAPI:" 10 78 "${LAPI_PORT}" 3>&1 1>&2 2>&3) || return
  else
    print_header
    read -rp "Новый LAPI port [${LAPI_PORT}]: " new_lapi_port
    [[ -n "${new_lapi_port}" ]] || { warn "Порт не изменён."; pause; return; }
  fi

  if ! is_valid_port "${new_lapi_port}"; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
      whiptail --title " Ошибка " --msgbox "Некорректный порт: ${new_lapi_port}" 8 78
    else
      warn "Некорректный порт: ${new_lapi_port}"
      pause
    fi
    return
  fi

  LAPI_PORT="${new_lapi_port}"
  save_env
  configure_crowdsec_lapi
  install_or_update_web_ui
  configure_ufw_full

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Успех " --msgbox "Порт LAPI обновлён: ${LAPI_PORT}" 8 78
  else
    ok "Порт LAPI обновлён: ${LAPI_PORT}"
    pause
  fi
}

change_public_addr() {
  safe_source_env
  local new_public
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    new_public=$(whiptail --title " Внешний адрес LAPI " --inputbox "Текущий адрес: ${PUBLIC_ADDR:-не задан}\n\nВведите новый внешний IP или DNS (оставьте пустым, чтобы удалить):" 12 78 "${PUBLIC_ADDR}" 3>&1 1>&2 2>&3) || return
  else
    print_header
    echo "Сейчас: ${PUBLIC_ADDR:-не задан}"
    read -rp "Новый внешний адрес или Enter чтобы убрать: " new_public
  fi

  PUBLIC_ADDR="${new_public:-}"
  save_env

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Успех " --msgbox "Внешний адрес обновлён.\nLAPI URL для VPS: ${VPS_LAPI_URL}" 10 78
  else
    ok "Внешний адрес обновлён. LAPI URL для VPS: ${VPS_LAPI_URL}"
    pause
  fi
}

regenerate_auto_token() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Регенерация токена " --yes-button "Продолжить" --no-button "Отмена" --yesno "Новые серверы должны будут использовать новый токен.\n\nПерегенерировать токен авторегистрации?" 12 78 || return
  else
    print_header
    echo "Новые серверы должны будут использовать новый токен."
    read -rp "Перегенерировать token? [y/N]: " confirm
    [[ "${confirm:-N}" =~ ^[Yy]$ ]] || { echo "Отменено."; pause; return; }
  fi

  AUTO_REG_TOKEN="$(openssl rand -hex 32)"
  save_env
  configure_crowdsec_lapi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Успех " --msgbox "Auto-registration token обновлён." 8 78
  else
    ok "Auto-registration token обновлён."
    pause
  fi
}

regenerate_bouncer_key() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Регенерация bouncer key " --yes-button "Продолжить" --no-button "Отмена" --yesno "Удалённые bouncers нужно будет перенастроить на новый ключ.\n\nСоздать новый shared bouncer key?" 12 78 || return
  else
    print_header
    echo "Удалённые bouncer нужно будет перенастроить на новый ключ."
    read -rp "Создать новый shared bouncer key? [y/N]: " confirm
    [[ "${confirm:-N}" =~ ^[Yy]$ ]] || { echo "Отменено."; pause; return; }
  fi

  SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"
  save_env
  if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
    docker exec crowdsec cscli bouncers delete shared-firewall-bouncer >/dev/null 2>&1 || true
    docker exec crowdsec cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null || true
  else
    cscli bouncers delete shared-firewall-bouncer >/dev/null 2>&1 || true
    cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null || true
  fi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    whiptail --title " Успех " --msgbox "Shared bouncer key обновлён." 8 78
  else
    ok "Shared bouncer key обновлён."
    pause
  fi
}

restart_services_cmd() {
  if [[ "${WEB_UI_TYPE:-simple}" == "manager" && -f "${MANAGER_COMPOSE_FILE}" ]]; then
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose up -d) || true
  else
    systemctl restart crowdsec || true
  fi
  systemctl restart docker || true
  if [[ -d "${COMPOSE_DIR}" ]]; then cd "${COMPOSE_DIR}" && docker compose up -d || true; fi
  if [[ -d "${MANAGER_COMPOSE_DIR}" ]]; then cd "${MANAGER_COMPOSE_DIR}" && docker compose up -d || true; fi
}
restart_services() {
  run_menu_step "Перезапуск сервисов" restart_services_cmd
}

show_firewall() {
  local tmp
  tmp="$(mktemp)"
  { print_header; ufw status verbose || true; } >"${tmp}"
  show_file "Firewall" "${tmp}"
  rm -f "${tmp}"
}

detect_web_uis() {
  local found="no"
  echo "Обнаруженные веб-морды:"
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^crowdsec-web-ui$'; then
    echo "  - Simple Web UI: контейнер crowdsec-web-ui"
    found="yes"
  fi
  if [[ -f "${COMPOSE_FILE}" ]]; then
    echo "  - Simple Web UI: ${COMPOSE_FILE}"
    found="yes"
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^crowdsec-manager$'; then
    echo "  - CrowdSec Manager: контейнер crowdsec-manager"
    found="yes"
  fi
  if [[ -f "${MANAGER_COMPOSE_FILE}" ]]; then
    echo "  - CrowdSec Manager: ${MANAGER_COMPOSE_FILE}"
    found="yes"
  fi
  [[ "${found}" == "yes" ]] || echo "  не найдены"
}

show_web_ui_installations() {
  local tmp
  tmp="$(mktemp)"
  { print_header; detect_web_uis; } >"${tmp}"
  show_file "Веб-морды" "${tmp}"
  rm -f "${tmp}"
}

remove_simple_web_ui_cmd() {
  if [[ -f "${COMPOSE_FILE}" ]]; then
    (cd "${COMPOSE_DIR}" && docker compose down --remove-orphans)
  else
    docker rm -f crowdsec-web-ui >/dev/null 2>&1
  fi
  rm -rf "${COMPOSE_DIR}"
}
remove_simple_web_ui() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    if tui_yesno "Удаление Web UI" "Удалить Simple Web UI (crowdsec-web-ui) и его compose-файлы?\n\nДанные CrowdSec/LAPI не будут затронуты."; then
      run_menu_step "Удаление Simple Web UI" remove_simple_web_ui_cmd
    fi
  else
    print_header
    read -rp "Удалить Simple Web UI (crowdsec-web-ui) и его compose-файлы? [y/N]: " confirm
    if [[ "${confirm:-N}" =~ ^[Yy]$ ]]; then
      log "Удаляю Simple Web UI..."
      if remove_simple_web_ui_cmd; then
        ok "Simple Web UI удалена."
      else
        warn "Ошибка при удалении Simple Web UI."
      fi
    else
      echo "Отменено."
    fi
    pause
  fi
}

reinstall_simple_web_ui_cmd() {
  if [[ -f "${COMPOSE_FILE}" ]]; then
    (cd "${COMPOSE_DIR}" && docker compose down --remove-orphans) || true
  else
    docker rm -f crowdsec-web-ui >/dev/null 2>&1 || true
  fi
  rm -rf "${COMPOSE_DIR}"
  create_or_update_webui_machine
  install_or_update_web_ui
  configure_ufw_full
}
reinstall_simple_web_ui() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    if tui_yesno "Переустановка Web UI" "Переустановить Simple Web UI?\n\nСтарый контейнер и compose-директория будут удалены. CrowdSec/LAPI не будут затронуты."; then
      run_menu_step "Переустановка Simple Web UI" reinstall_simple_web_ui_cmd
    fi
  else
    print_header
    read -rp "Переустановить Simple Web UI? [y/N]: " confirm
    if [[ "${confirm:-N}" =~ ^[Yy]$ ]]; then
      reinstall_simple_web_ui_cmd
      ok "Simple Web UI переустановлена."
    else
      echo "Отменено."
    fi
    pause
  fi
}

show_crowdsec_manager_note() {
  safe_source_env
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    echo "CrowdSec Manager устанавливается как отдельный режим central-сервера."
    echo
    echo "Что будет сделано при миграции:"
    echo "  - backup /etc/crowdsec и /var/lib/crowdsec;"
    echo "  - остановка и удаление apt/systemd CrowdSec;"
    echo "  - удаление текущих веб-морд;"
    echo "  - установка Dockerized CrowdSec + CrowdSec Manager;"
    echo "  - сохранение текущего LAPI-порта ${LAPI_PORT} для VPS."
    echo
    echo "Важно:"
    echo "  подключённые VPS могут потребовать повторной регистрации/валидации,"
    echo "  потому что engine и база CrowdSec будут заменены на Dockerized CrowdSec."
  } >"${tmp}"
  show_file "CrowdSec Manager" "${tmp}"
  rm -f "${tmp}"
}

migrate_to_crowdsec_manager_cmd() {
  install_or_update_docker
  install_or_update_crowdsec_manager
  configure_ufw_full
}
migrate_to_crowdsec_manager() {
  safe_source_env
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    if tui_yesno "Миграция на CrowdSec Manager" "Будет выполнено:\n\n- backup /etc/crowdsec и /var/lib/crowdsec;\n- удаление apt/systemd CrowdSec;\n- удаление текущих веб-морд;\n- установка Dockerized CrowdSec + CrowdSec Manager;\n- сохранение текущего LAPI-порта ${LAPI_PORT}.\n\nПродолжить?"; then
      run_menu_step "Миграция на CrowdSec Manager" migrate_to_crowdsec_manager_cmd
    fi
  else
    print_header
    echo "Будет выполнено:"
    echo "  - backup /etc/crowdsec и /var/lib/crowdsec"
    echo "  - удаление apt/systemd CrowdSec"
    echo "  - удаление текущих веб-морд"
    echo "  - установка Dockerized CrowdSec + CrowdSec Manager"
    echo "  - сохранение текущего LAPI-порта ${LAPI_PORT}"
    echo
    read -rp "Продолжить миграцию? [y/N]: " confirm
    if [[ "${confirm:-N}" =~ ^[Yy]$ ]]; then
      migrate_to_crowdsec_manager_cmd
      ok "Миграция на CrowdSec Manager завершена."
    else
      echo "Отменено."
    fi
    pause
  fi
}

reapply_all_settings_cmd() {
  if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
    configure_docker_crowdsec_lapi
    create_or_update_shared_bouncer_key
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)
  else
    configure_crowdsec_lapi
    create_or_update_webui_machine
    create_or_update_shared_bouncer_key
    install_or_update_web_ui
  fi
  configure_ufw_full
  install_menu_files
}
reapply_all_settings() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]]; then
    if tui_yesno "Применение настроек" "Повторно применить все настройки?\n\nБудут обновлены: конфигурация LAPI, Web UI, правила UFW и автозапуск меню."; then
      run_menu_step "Применение всех настроек" reapply_all_settings_cmd
    fi
  else
    print_header
    echo "Повторное применение всех настроек."
    echo "Будут обновлены: CrowdSec LAPI, Web UI docker-compose, UFW правила, автозапуск меню."
    read -rp "Продолжить? [Y/n]: " confirm
    if [[ "${confirm:-Y}" =~ ^[Yy]$ ]]; then
      reapply_all_settings_cmd
      ok "Все настройки применены."
    else
      echo "Отменено."
    fi
    pause
  fi
}

update_system_only() {
  run_menu_step "Обновление системных пакетов Debian" upgrade_system_packages
}

update_docker_only() {
  run_menu_step "Обновление Docker" install_or_update_docker
}

update_crowdsec_only() {
  if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
    run_menu_step "Обновление CrowdSec в Docker" install_or_update_crowdsec_manager
  else
    run_menu_step "Обновление CrowdSec" install_or_update_crowdsec
  fi
}

update_web_ui_only() {
  if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
    run_menu_step "Обновление CrowdSec Manager" install_or_update_crowdsec_manager
  else
    run_menu_step "Обновление Simple Web UI" install_or_update_web_ui
  fi
}

update_installed_stack() {
  if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
    run_menu_step "Обновление Docker" install_or_update_docker
    run_menu_step "Обновление CrowdSec + Manager" install_or_update_crowdsec_manager
  else
    run_menu_step "Обновление Docker" install_or_update_docker
    run_menu_step "Обновление CrowdSec" install_or_update_crowdsec
    run_menu_step "Обновление Simple Web UI" install_or_update_web_ui
  fi
  run_menu_step "Настройка Firewall" configure_ufw_full
}

show_logs() {
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
      echo "Логи CrowdSec Manager (последние 100 строк):"
      docker logs --tail 100 crowdsec-manager 2>&1 || true
      echo
      echo "Логи CrowdSec Docker (последние 100 строк):"
      docker logs --tail 100 crowdsec 2>&1 || true
    elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -q '^crowdsec-web-ui$'; then
      echo "Логи Simple Web UI (последние 100 строк):"
      docker logs --tail 100 crowdsec-web-ui 2>&1 || true
    else
      echo "Веб-морда не установлена или не запущена в Docker."
    fi
  } >"${tmp}"
  show_file "Логи" "${tmp}"
  rm -f "${tmp}"
}

show_crowdsec_info() {
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    local cmd="cscli"
    if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
      cmd="docker exec crowdsec cscli"
    fi
    echo "=== Машины (machines) ==="
    $cmd machines list 2>&1 || true
    echo
    echo "=== Баунсеры (bouncers) ==="
    $cmd bouncers list 2>&1 || true
    echo
    echo "=== Активные решения (decisions) ==="
    $cmd decisions list -l 50 2>&1 || true
    echo
    echo "=== Последние алерты (alerts) ==="
    $cmd alerts list -l 20 2>&1 || true
  } >"${tmp}"
  show_file "Информация CrowdSec" "${tmp}"
  rm -f "${tmp}"
}

disable_login_menu() { print_header; rm -f "${PROFILE_FILE}"; ok "Автозапуск меню отключён."; pause; }
enable_login_menu() { print_header; install_menu_files; ok "Автозапуск меню включён."; pause; }
repair_menu_installation() { print_header; update_menu_from_github; ok "Команда меню обновлена: sudo crowdsec-central-menu"; pause; }

show_versions() {
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    echo "Debian/Ubuntu:"
    [[ -f /etc/os-release ]] && grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '"' || true
    echo; echo "CrowdSec:"; command -v cscli >/dev/null 2>&1 && cscli version || echo "не установлен"
    echo; echo "Docker:"; command -v docker >/dev/null 2>&1 && { docker --version; docker compose version; } || echo "не установлен"
    echo; echo "Web UI image:"; command -v docker >/dev/null 2>&1 && docker images "${WEBUI_IMAGE}" || true
  } >"${tmp}"
  show_file "Версии" "${tmp}"
  rm -f "${tmp}"
}

test_webui_lapi() {
  safe_source_env
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    echo "Проверяю LAPI с хоста:"
    curl -i "http://127.0.0.1:${LAPI_PORT}/health" || true
    echo
    echo "Проверяю LAPI из контейнера Web UI через node fetch:"
    docker exec crowdsec-web-ui sh -lc "node -e 'fetch(\"http://host.docker.internal:${LAPI_PORT}/health\").then(r=>r.text()).then(console.log).catch(e=>{console.error(e); process.exit(1)})'" || true
  } >"${tmp}"
  show_file "Проверка LAPI" "${tmp}"
  rm -f "${tmp}"
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
checkbox=black,lightgray
actcheckbox=white,red
entry=black,white
label=black,lightgray
listbox=black,lightgray
actlistbox=white,red
textbox=black,lightgray
'
}

ensure_tui_tools() {
  command -v whiptail >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    log "Устанавливаю TUI-зависимости меню: whiptail, less..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || return 1
    apt-get install -y whiptail less || return 1
  fi
  command -v whiptail >/dev/null 2>&1
}

tui_summary() {
  safe_source_env
  cat <<EOF
Web UI: ${LOCAL_WEB_UI}
LAPI:   ${VPS_LAPI_URL}
CIDR:   ${ALLOWED_RANGES:-не заданы}
EOF
}

run_menu_action() {
  safe_source_env
  case "${1}" in
    status) show_status; pause ;;
    connect) show_connection_info; pause ;;
    envfile) show_tokens_file; pause ;;
    add_range) add_allowed_range ;;
    remove_range) remove_allowed_range ;;
    replace_ranges) replace_allowed_ranges ;;
    web_addr) change_lan_ip_or_web_port ;;
    lapi_port) change_lapi_port ;;
    public_addr) change_public_addr ;;
    auto_token) regenerate_auto_token ;;
    bouncer_key) regenerate_bouncer_key ;;
    restart) restart_services ;;
    update_webui) update_web_ui_only ;;
    logs) show_logs ;;
    crowdsec_info) show_crowdsec_info ;;
    firewall) show_firewall ;;
    reapply) reapply_all_settings ;;
    disable_autostart) disable_login_menu ;;
    enable_autostart) enable_login_menu ;;
    update_all) update_installed_stack ;;
    update_system) update_system_only ;;
    update_docker) update_docker_only ;;
    update_crowdsec) update_crowdsec_only ;;
    versions) show_versions ;;
    webui_detect) show_web_ui_installations ;;
    webui_reinstall) reinstall_simple_web_ui ;;
    webui_remove) remove_simple_web_ui ;;
    manager_note) show_crowdsec_manager_note ;;
    manager_install) migrate_to_crowdsec_manager ;;
    repair_menu) repair_menu_installation ;;
    test_lapi) test_webui_lapi ;;
    exit) exit 0 ;;
  esac
}

menu_loop_whiptail() {
  require_root
  tui_theme
  export CROWDSEC_TUI_MODE="whiptail"
  clear || true
  while true; do
    local category choice summary
    summary="$(tui_summary)"
    category="$(whiptail \
      --backtitle "Панель управления CrowdSec Central | версия ${SCRIPT_VERSION}" \
      --title " CrowdSec Central " \
      --cancel-button "Выход" \
      --ok-button "Выбрать" \
      --notags \
      --menu "Выберите раздел:\nИспользуйте TAB или стрелки для навигации, ENTER для выбора.\n\n${summary}" \
      23 76 8 \
      "status" "Статус и данные" \
      "access" "Доступ к LAPI" \
      "network" "Сеть и ключи" \
      "webui" "Веб-морда" \
      "service" "Обслуживание" \
      "system" "Обновления и диагностика" \
      "menu" "Настройки меню" \
      "exit" "Выход" \
      3>&1 1>&2 2>&3)" || exit 0
    [[ "${category}" == "exit" ]] && exit 0

    case "${category}" in
      status)
        choice="$(whiptail --backtitle "Панель управления CrowdSec Central | версия ${SCRIPT_VERSION}" --title " Статус и данные " --cancel-button "Назад" --ok-button "Выбрать" --notags --menu "Выберите действие:" 18 76 5 \
          "status" "Статус сервисов и портов" \
          "connect" "Данные подключения VPS" \
          "envfile" "Показать central.env" \
          3>&1 1>&2 2>&3)" || continue
        ;;
      access)
        choice="$(whiptail --backtitle "Панель управления CrowdSec Central | версия ${SCRIPT_VERSION}" --title " Доступ к LAPI " --cancel-button "Назад" --ok-button "Выбрать" --notags --menu "Выберите действие:" 18 76 6 \
          "add_range" "Добавить IP/CIDR к LAPI" \
          "remove_range" "Удалить IP/CIDR из LAPI" \
          "replace_ranges" "Заменить весь список IP/CIDR" \
          "firewall" "Показать firewall/UFW" \
          3>&1 1>&2 2>&3)" || continue
        ;;
      network)
        choice="$(whiptail --backtitle "Панель управления CrowdSec Central | версия ${SCRIPT_VERSION}" --title " Сеть и ключи " --cancel-button "Назад" --ok-button "Выбрать" --notags --menu "Выберите действие:" 20 76 8 \
          "web_addr" "Изменить LAN IP или порт Web UI" \
          "lapi_port" "Изменить порт LAPI" \
          "public_addr" "Изменить внешний IP/DDNS для VPS" \
          "auto_token" "Перегенерировать auto-registration token" \
          "bouncer_key" "Перегенерировать shared bouncer key" \
          "test_lapi" "Проверить доступ Web UI к LAPI" \
          3>&1 1>&2 2>&3)" || continue
        ;;
      webui)
        choice="$(whiptail --backtitle "Панель управления CrowdSec Central | версия ${SCRIPT_VERSION}" --title " Веб-морда " --cancel-button "Назад" --ok-button "Выбрать" --notags --menu "Выберите действие:" 19 76 6 \
          "webui_detect" "Показать установленные веб-морды" \
          "webui_reinstall" "Переустановить Simple Web UI" \
          "webui_remove" "Удалить Simple Web UI" \
          "manager_install" "Установить CrowdSec Manager (миграция)" \
          "manager_note" "CrowdSec Manager: что будет изменено" \
          3>&1 1>&2 2>&3)" || continue
        ;;
      service)
        choice="$(whiptail --backtitle "Панель управления CrowdSec Central | версия ${SCRIPT_VERSION}" --title " Обслуживание " --cancel-button "Назад" --ok-button "Выбрать" --notags --menu "Выберите действие:" 20 76 7 \
          "restart" "Перезапустить CrowdSec, Docker и Web UI" \
          "update_webui" "Обновить только контейнер Web UI" \
          "logs" "Показать логи Web UI" \
          "crowdsec_info" "Машины, баунсеры, алерты и решения" \
          "reapply" "Повторно применить все настройки" \
          3>&1 1>&2 2>&3)" || continue
        ;;
      system)
        choice="$(whiptail --backtitle "Панель управления CrowdSec Central | версия ${SCRIPT_VERSION}" --title " Обновления и диагностика " --cancel-button "Назад" --ok-button "Выбрать" --notags --menu "Выберите действие:" 20 76 7 \
          "update_all" "Обновить весь стек" \
          "update_system" "Обновить пакеты Debian" \
          "update_docker" "Обновить Docker" \
          "update_crowdsec" "Обновить CrowdSec" \
          "versions" "Показать версии ПО" \
          3>&1 1>&2 2>&3)" || continue
        ;;
      menu)
        choice="$(whiptail --backtitle "Панель управления CrowdSec Central | версия ${SCRIPT_VERSION}" --title " Настройки меню " --cancel-button "Назад" --ok-button "Выбрать" --notags --menu "Выберите действие:" 18 76 5 \
          "disable_autostart" "Отключить автозапуск меню при входе" \
          "enable_autostart" "Включить автозапуск меню при входе" \
          "repair_menu" "Обновить или переустановить команду меню" \
          3>&1 1>&2 2>&3)" || continue
        ;;
    esac
    run_menu_action "${choice}"
  done
}

menu_loop_plain() {
  require_root
  clear || true
  while true; do
    print_header
    safe_source_env
    echo "+----------------------------------------------------------+"
    printf "| %-56s |\n" "Веб-морда: ${LOCAL_WEB_UI}"
    printf "| %-56s |\n" "LAPI для VPS: ${VPS_LAPI_URL}"
    printf "| %-56s |\n" "Allowed IP/CIDR: ${ALLOWED_RANGES:-не заданы}"
    echo "+----------------------------------------------------------+"
    echo
    echo "[ СТАТУС И ДАННЫЕ ]"
    echo "  1) Показать статус"
    echo "  2) Показать адреса, токены и данные подключения"
    echo "  3) Показать файл настроек central.env"
    echo
    echo "[ ДОСТУП К LAPI ]"
    echo "  4) Добавить IP/CIDR для доступа к LAPI"
    echo "  5) Удалить IP/CIDR из доступа к LAPI по номеру"
    echo "  6) Полностью заменить список IP/CIDR"
    echo
    echo "[ СЕТЬ И КЛЮЧИ ]"
    echo "  7) Изменить LAN IP или порт веб-морды"
    echo "  8) Изменить порт LAPI"
    echo "  9) Изменить внешний адрес или DDNS для VPS"
    echo " 10) Перегенерировать auto-registration token"
    echo " 11) Создать новый shared bouncer key"
    echo
    echo "[ ОБСЛУЖИВАНИЕ ]"
    echo " 12) Перезапустить CrowdSec, Docker и Web UI"
    echo " 13) Обновить только контейнер веб-морды"
    echo " 14) Показать логи веб-морды"
    echo " 15) Показать machines, bouncers, alerts и decisions"
    echo " 16) Показать firewall"
    echo " 17) Повторно применить все настройки"
    echo " 18) Отключить автозапуск меню при входе"
    echo " 19) Включить автозапуск меню при входе"
    echo " 20) Обновить всё установленное ПО"
    echo " 21) Обновить только системные пакеты Debian"
    echo " 22) Обновить только Docker"
    echo " 23) Обновить только CrowdSec"
    echo " 24) Показать версии установленного ПО"
    echo " 25) Починить или переустановить команду меню"
    echo " 26) Проверить доступ Web UI к LAPI"
    echo
    echo "  0) Выход"
    echo
    read -rp "Выбери действие [0-26]: " choice
    case "${choice}" in
      1) show_status; pause ;;
      2) show_connection_info; pause ;;
      3) show_tokens_file; pause ;;
      4) add_allowed_range ;;
      5) remove_allowed_range ;;
      6) replace_allowed_ranges ;;
      7) change_lan_ip_or_web_port ;;
      8) change_lapi_port ;;
      9) change_public_addr ;;
      10) regenerate_auto_token ;;
      11) regenerate_bouncer_key ;;
      12) restart_services ;;
      13) update_web_ui_only ;;
      14) show_logs ;;
      15) show_crowdsec_info ;;
      16) show_firewall ;;
      17) reapply_all_settings ;;
      18) disable_login_menu ;;
      19) enable_login_menu ;;
      20) update_installed_stack ;;
      21) update_system_only ;;
      22) update_docker_only ;;
      23) update_crowdsec_only ;;
      24) show_versions ;;
      25) repair_menu_installation ;;
      26) test_webui_lapi ;;
      0) exit 0 ;;
      *) echo "Неизвестный пункт меню."; pause ;;
    esac
  done
}

menu_loop() {
  if [[ -t 0 && -t 1 ]] && ensure_tui_tools; then
    menu_loop_whiptail
  else
    warn "TUI-меню недоступно: нет TTY или не удалось установить whiptail. Открываю простой fallback."
    pause
    menu_loop_plain
  fi
}

case "${1:-}" in
  --install) full_install ;;
  --menu) menu_loop ;;
  *)
    if [[ "$(basename "$0")" == "crowdsec-central-menu" || -f "${ENV_FILE}" ]]; then
      menu_loop
    else
      full_install
    fi
    ;;
esac
