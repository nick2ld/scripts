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
# - Lets you choose CrowdSec Hub collections from the real cscli list.
# - Installs firewall bouncer and points it to the central LAPI with a bouncer key.
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
SCRIPT_VERSION="v0.1.0"
SCRIPT_RELEASE_DATE="2026-05-22"

log() { echo -e "${BLUE}==>${NC} $*"; }
ok() { echo -e "${GREEN}OK:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
fail() { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
pause() { echo; read -rp "Нажми Enter для продолжения..." _ || true; }
is_interactive() { [[ -t 0 ]]; }
safe_clear() {
  [[ -t 1 ]] || return 0
  [[ -n "${TERM:-}" && "${TERM}" != "dumb" ]] || return 0
  clear || true
}
tui_available() {
  type -P dialog >/dev/null 2>&1 || type -P whiptail >/dev/null 2>&1
}
whiptail() {
  local bin
  if bin="$(type -P dialog 2>/dev/null)"; then
    local args=(--no-mouse --no-shadow)
    local nl arg
    printf -v nl '\n'
    while (($#)); do
      case "$1" in
        --notags) args+=(--no-tags) ;;
        --cancel-button) shift; arg="${1:-}"; args+=(--cancel-label "${arg//\\n/${nl}}") ;;
        --ok-button) shift; arg="${1:-}"; args+=(--ok-label "${arg//\\n/${nl}}") ;;
        --yes-button) shift; arg="${1:-}"; args+=(--yes-label "${arg//\\n/${nl}}") ;;
        --no-button) shift; arg="${1:-}"; args+=(--no-label "${arg//\\n/${nl}}") ;;
        *) arg="$1"; args+=("${arg//\\n/${nl}}") ;;
      esac
      shift || true
    done
    command "${bin}" "${args[@]}"
    return
  fi
  if bin="$(type -P whiptail 2>/dev/null)"; then
    command "${bin}" "$@"
    return
  fi
  return 127
}
require_interactive_install() {
  if ! is_interactive; then
    fail "Интерактивная установка не работает через pipe. Скачай скрипт во временный файл и запусти его: tmp=\"\$(mktemp)\" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/vps.sh -o \"\$tmp\" && bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc"
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
quote_env() {
  printf '%q' "${1:-}"
}
tui_theme() {
  local dialogrc="/tmp/crowdsec-dialogrc-${UID:-0}"
  cat > "${dialogrc}" <<'EOF'
use_shadow = OFF
use_colors = ON
screen_color = (WHITE,BLUE,ON)
shadow_color = (BLUE,BLUE,OFF)
dialog_color = (WHITE,BLUE,OFF)
title_color = (YELLOW,BLUE,ON)
border_color = (CYAN,BLUE,ON)
border2_color = (CYAN,BLUE,ON)
button_active_color = (BLACK,CYAN,ON)
button_inactive_color = (WHITE,BLUE,OFF)
button_key_active_color = (BLACK,CYAN,ON)
button_key_inactive_color = (YELLOW,BLUE,ON)
button_label_active_color = (BLACK,CYAN,ON)
button_label_inactive_color = (WHITE,BLUE,OFF)
inputbox_color = (WHITE,BLUE,OFF)
inputbox_border_color = (CYAN,BLUE,ON)
inputbox_border2_color = (CYAN,BLUE,ON)
searchbox_color = (WHITE,BLUE,OFF)
searchbox_title_color = (YELLOW,BLUE,ON)
searchbox_border_color = (CYAN,BLUE,ON)
searchbox_border2_color = (CYAN,BLUE,ON)
position_indicator_color = (YELLOW,BLUE,ON)
menubox_color = (WHITE,BLUE,OFF)
menubox_border_color = (CYAN,BLUE,ON)
menubox_border2_color = (CYAN,BLUE,ON)
item_color = (WHITE,BLUE,OFF)
item_selected_color = (BLACK,CYAN,ON)
tag_color = (YELLOW,BLUE,ON)
tag_selected_color = (BLACK,CYAN,ON)
tag_key_color = (YELLOW,BLUE,ON)
tag_key_selected_color = (BLACK,CYAN,ON)
check_color = (WHITE,BLUE,OFF)
check_selected_color = (BLACK,CYAN,ON)
itemhelp_color = (WHITE,BLUE,OFF)
form_active_text_color = (BLACK,CYAN,ON)
form_text_color = (WHITE,BLUE,OFF)
form_item_readonly_color = (CYAN,BLUE,ON)
gauge_color = (YELLOW,BLUE,ON)
uarrow_color = (YELLOW,BLUE,ON)
darrow_color = (YELLOW,BLUE,ON)
EOF
  export DIALOGRC="${dialogrc}"
  export NEWT_COLORS='
root=white,blue
border=cyan,blue
window=white,blue
shadow=blue,blue
title=yellow,blue
button=white,blue
actbutton=black,cyan
entry=white,blue
label=white,blue
textbox=white,blue
'
}
bootstrap_installer_tui() {
  type -P dialog >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || return 1
  safe_clear
  echo "Подготовка интерактивного установщика..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/tmp/crowdsec-vps-bootstrap.log 2>&1 || return 1
  apt-get install -y dialog whiptail >>/tmp/crowdsec-vps-bootstrap.log 2>&1 || return 1
  tui_available
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
  if tui_available; then
    whiptail --title " CrowdSec VPS Node " --infobox "${title}\n\nПодробный лог пишется во временный файл." 9 72 || true
  else
    log "${title}"
  fi
  if "$@" >"${log_file}" 2>&1; then
    rm -f "${log_file}"
    return 0
  fi
  if tui_available; then
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
  COLLECTION_SELECTION_MODE="${COLLECTION_SELECTION_MODE:-manual}"
  SELECTED_COLLECTIONS="${SELECTED_COLLECTIONS:-}"
  HUB_ITEM_SELECTION_MODE="${HUB_ITEM_SELECTION_MODE:-none}"
  SELECTED_HUB_ITEMS="${SELECTED_HUB_ITEMS:-}"
  FIREWALL_BOUNCER_PACKAGE="${FIREWALL_BOUNCER_PACKAGE:-}"
  FIREWALL_BOUNCER_MODE="${FIREWALL_BOUNCER_MODE:-}"
}

save_env() {
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"
cat > "${ENV_FILE}" <<ENV
CENTRAL_LAPI_URL=$(quote_env "${CENTRAL_LAPI_URL}")
AUTO_REG_TOKEN=$(quote_env "${AUTO_REG_TOKEN}")
SHARED_BOUNCER_KEY=$(quote_env "${SHARED_BOUNCER_KEY}")
MACHINE_NAME=$(quote_env "${MACHINE_NAME}")
INSTALL_FIREWALL_BOUNCER=$(quote_env "${INSTALL_FIREWALL_BOUNCER}")
COLLECTION_SELECTION_MODE=$(quote_env "${COLLECTION_SELECTION_MODE}")
SELECTED_COLLECTIONS=$(quote_env "${SELECTED_COLLECTIONS}")
HUB_ITEM_SELECTION_MODE=$(quote_env "${HUB_ITEM_SELECTION_MODE}")
SELECTED_HUB_ITEMS=$(quote_env "${SELECTED_HUB_ITEMS}")
FIREWALL_BOUNCER_PACKAGE=$(quote_env "${FIREWALL_BOUNCER_PACKAGE}")
FIREWALL_BOUNCER_MODE=$(quote_env "${FIREWALL_BOUNCER_MODE}")
ENV
  chmod 600 "${ENV_FILE}"
}

ask_settings() {
  load_env_if_exists
  if tui_available; then
    tui_theme
    whiptail --title " CrowdSec VPS Node " --msgbox "Подключение VPS к центральному CrowdSec LAPI.\n\nДанные возьми в меню центрального сервера: sudo crowdsec-central-menu" 12 78
    CENTRAL_LAPI_URL="$(tui_input "Central LAPI" "Central LAPI URL" "${CENTRAL_LAPI_URL:-http://1.2.3.4:8080}")" || exit 1
    AUTO_REG_TOKEN="$(tui_input "Central LAPI" "AUTO_REG_TOKEN" "${AUTO_REG_TOKEN:-}")" || exit 1
    SHARED_BOUNCER_KEY="$(tui_input "Firewall Bouncer" "BOUNCER_KEY\n\nЛучше создать индивидуальный ключ на central:\nСеть и ключи -> Создать bouncer key с именем VPS.\nТогда это имя будет видно в CrowdSec Manager." "${SHARED_BOUNCER_KEY:-}")" || exit 1
    MACHINE_NAME="$(tui_input "Machine" "Machine name" "${MACHINE_NAME}")" || exit 1
    if tui_yesno "Firewall Bouncer" "Ставить firewall-bouncer для автоматической блокировки IP?"; then
      INSTALL_FIREWALL_BOUNCER="yes"
    else
      INSTALL_FIREWALL_BOUNCER="no"
    fi
    COLLECTION_SELECTION_MODE="$(whiptail --title " Collections " --cancel-button "Отмена" --ok-button "Выбрать" --notags --menu "Как выбрать CrowdSec collections после установки агента?" 16 86 3 \
      "manual" "Показать список из CrowdSec Hub и выбрать вручную" \
      "auto" "Поставить только базовые и похожие на найденный софт" \
      "base" "Поставить только linux + sshd" \
      3>&1 1>&2 2>&3)" || exit 1
    HUB_ITEM_SELECTION_MODE="$(whiptail --title " Дополнительные Hub elements " --cancel-button "Отмена" --ok-button "Выбрать" --notags --menu "Выбирать отдельно scenarios/parsers/appsec и прочее?\n\nОбычно достаточно collections, потому что они подтягивают связанные элементы." 18 90 2 \
      "none" "Нет, только collections" \
      "manual" "Да, показать расширенный выбор Hub elements" \
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

  prompt_default input_bouncer "BOUNCER_KEY (лучше индивидуальный ключ из central-меню для имени VPS в Manager): " "${SHARED_BOUNCER_KEY:-}"
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
  echo "CrowdSec collections будут выбраны после установки агента из реального списка CrowdSec Hub."
  echo "manual - показать checklist и выбрать вручную"
  echo "auto   - поставить базовые и похожие на найденный софт"
  echo "base   - поставить только linux + sshd"
  prompt_default input_collections "Режим выбора collections [manual]: " "manual"
  COLLECTION_SELECTION_MODE="${input_collections:-manual}"

  prompt_default input_hub_items "Выбирать отдельно scenarios/parsers/appsec/context? [none/manual]: " "none"
  HUB_ITEM_SELECTION_MODE="${input_hub_items:-none}"

  save_env
}

install_base() {
  log "Устанавливаю базовые пакеты..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg lsb-release apt-transport-https python3 python3-yaml jq sudo iproute2 procps nano rsync iptables nftables dialog whiptail less
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

detected_software_text() {
  {
    echo "Команды:"
    command -v nginx >/dev/null 2>&1 && echo "nginx"
    command -v apache2 >/dev/null 2>&1 && echo "apache apache2"
    command -v caddy >/dev/null 2>&1 && echo "caddy"
    command -v traefik >/dev/null 2>&1 && echo "traefik"
    command -v haproxy >/dev/null 2>&1 && echo "haproxy"
    echo
    echo "systemd:"
    systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null | awk '{print $1}' || true
    echo
    echo "docker:"
    if command -v docker >/dev/null 2>&1; then
      docker ps --format '{{.Names}} {{.Image}} {{.Command}}' 2>/dev/null || true
    fi
  } | tr '[:upper:]' '[:lower:]'
}

list_hub_collections() {
  cscli hub update >/dev/null 2>&1 || true
  if cscli collections list -o json >/tmp/crowdsec-collections.json 2>/dev/null; then
    python3 - /tmp/crowdsec-collections.json <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    data = json.load(f)
if isinstance(data, dict):
    data = data.get("collections") or data.get("items") or data.get("data") or []
rows = []
for item in data:
    if not isinstance(item, dict):
        continue
    name = item.get("name") or item.get("path") or item.get("full_path") or item.get("fullpath")
    if not name:
        continue
    if "/" not in name:
        author = item.get("author") or item.get("source") or "crowdsecurity"
        name = f"{author}/{name}"
    desc = item.get("description") or item.get("status") or ""
    rows.append((name, " ".join(str(desc).split())[:70]))
for name, desc in sorted(set(rows)):
    print(f"{name}\t{desc}")
PY
    return
  fi
  cscli collections list -a 2>/dev/null | awk '/[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+/ {for (i=1;i<=NF;i++) if ($i ~ /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/) print $i "\t"}' | sort -u
}

list_hub_items_by_type() {
  local item_type="$1"
  if cscli "${item_type}" list -o json >/tmp/crowdsec-hub-items.json 2>/dev/null; then
    python3 - /tmp/crowdsec-hub-items.json <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    data = json.load(f)
if isinstance(data, dict):
    for key in ("items", "data", "parsers", "scenarios", "collections", "postoverflows", "contexts"):
        if isinstance(data.get(key), list):
            data = data[key]
            break
rows = []
for item in data if isinstance(data, list) else []:
    if not isinstance(item, dict):
        continue
    name = item.get("name") or item.get("path") or item.get("full_path") or item.get("fullpath")
    if not name:
        continue
    if "/" not in name:
        name = f"{item.get('author') or item.get('source') or 'crowdsecurity'}/{name}"
    desc = item.get("description") or item.get("status") or ""
    rows.append((name, " ".join(str(desc).split())[:70]))
for name, desc in sorted(set(rows)):
    print(f"{name}\t{desc}")
PY
    return
  fi
  cscli "${item_type}" list -a 2>/dev/null | awk '/[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+/ {for (i=1;i<=NF;i++) if ($i ~ /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/) print $i "\t"}' | sort -u
}

collection_is_suggested() {
  local collection="$1"
  local detected="$2"
  local short
  short="${collection##*/}"
  short="${short,,}"
  [[ "${collection}" =~ ^crowdsecurity/(linux|sshd)$ ]] && return 0
  grep -qiE "(^|[^a-z0-9])${short}([^a-z0-9]|$)" <<<"${detected}" && return 0
  case "${short}" in
    apache2) grep -qiE 'apache|apache2|httpd' <<<"${detected}" ;;
    nginx) grep -qiE 'nginx|nginxproxymanager|npm|proxy-manager' <<<"${detected}" ;;
    mysql) grep -qiE 'mysql|mariadb' <<<"${detected}" ;;
    postgresql) grep -qiE 'postgres|postgresql' <<<"${detected}" ;;
    wireguard) grep -qiE 'wireguard|wg-easy|amnezia-awg|awg' <<<"${detected}" ;;
    *) return 1 ;;
  esac
}

select_hub_collections() {
  load_env_if_exists
  local detected collections_file menu_file selected
  detected="$(detected_software_text)"
  collections_file="$(mktemp)"
  menu_file="$(mktemp)"
  list_hub_collections >"${collections_file}"
  if [[ ! -s "${collections_file}" ]]; then
    warn "Не удалось получить список collections из CrowdSec Hub. Будут установлены только базовые collections."
    SELECTED_COLLECTIONS="crowdsecurity/linux crowdsecurity/sshd"
    save_env
    rm -f "${collections_file}" "${menu_file}"
    return
  fi
  SELECTED_COLLECTIONS="crowdsecurity/linux crowdsecurity/sshd"
  if [[ "${COLLECTION_SELECTION_MODE}" == "base" ]]; then
    save_env
    rm -f "${collections_file}" "${menu_file}"
    return
  fi
  while IFS=$'\t' read -r collection desc; do
    [[ -n "${collection}" ]] || continue
    if collection_is_suggested "${collection}" "${detected}"; then
      SELECTED_COLLECTIONS="${SELECTED_COLLECTIONS} ${collection}"
      printf '%s\t%s\ton\n' "${collection}" "${desc:-${collection}}" >>"${menu_file}"
    elif [[ "${COLLECTION_SELECTION_MODE}" == "manual" ]]; then
      printf '%s\t%s\toff\n' "${collection}" "${desc:-${collection}}" >>"${menu_file}"
    fi
  done <"${collections_file}"
  SELECTED_COLLECTIONS="$(tr ' ' '\n' <<<"${SELECTED_COLLECTIONS}" | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  if [[ "${COLLECTION_SELECTION_MODE}" == "manual" && -s "${menu_file}" && tui_available ]]; then
    local args=()
    while IFS=$'\t' read -r tag item state; do
      args+=("${tag}" "${item:-${tag}}" "${state:-off}")
    done <"${menu_file}"
    selected="$(whiptail --title " CrowdSec Hub collections " --cancel-button "Назад" --ok-button "Установить" --checklist "Выбери collections для установки.\n\nПредвыбраны базовые и похожие на найденный софт/контейнеры." 30 110 18 "${args[@]}" 3>&1 1>&2 2>&3)" || selected="${SELECTED_COLLECTIONS}"
    SELECTED_COLLECTIONS="$(printf '%s\n' ${selected} | tr -d '"' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  fi
  [[ -n "${SELECTED_COLLECTIONS// }" ]] || SELECTED_COLLECTIONS="crowdsecurity/linux crowdsecurity/sshd"
  save_env
  rm -f "${collections_file}" "${menu_file}" /tmp/crowdsec-collections.json
}

install_collections() {
  load_env_if_exists
  [[ -n "${SELECTED_COLLECTIONS:-}" ]] || SELECTED_COLLECTIONS="crowdsecurity/linux crowdsecurity/sshd"
  log "Устанавливаю выбранные collections..."
  for collection in ${SELECTED_COLLECTIONS}; do
    log "Collection: ${collection}"
    cscli collections install "${collection}" || true
  done
  ok "Collections установлены или уже были установлены."
}

select_extra_hub_items() {
  load_env_if_exists
  [[ "${HUB_ITEM_SELECTION_MODE}" == "manual" ]] || return 0
  local item_type file selected args tag item state
  SELECTED_HUB_ITEMS=""
  for item_type in scenarios parsers postoverflows appsec-configs appsec-rules contexts; do
    tui_available || break
    if ! tui_yesno " Hub: ${item_type} " "Показать список ${item_type} из CrowdSec Hub?\n\nCollections обычно уже подтягивают нужные ${item_type}."; then
      continue
    fi
    file="$(mktemp)"
    list_hub_items_by_type "${item_type}" >"${file}"
    [[ -s "${file}" ]] || { rm -f "${file}"; continue; }
    args=()
    while IFS=$'\t' read -r tag item; do
      [[ -n "${tag}" ]] || continue
      state="off"
      args+=("${tag}" "${item:-${tag}}" "${state}")
    done <"${file}"
    selected="$(whiptail --title " Hub: ${item_type} " --cancel-button "Назад" --ok-button "Добавить" --checklist "Выбери ${item_type} для установки." 30 110 18 "${args[@]}" 3>&1 1>&2 2>&3)" || selected=""
    for item in ${selected}; do
      item="${item//\"/}"
      [[ -n "${item}" ]] && SELECTED_HUB_ITEMS="${SELECTED_HUB_ITEMS} ${item_type}:${item}"
    done
    rm -f "${file}"
  done
  SELECTED_HUB_ITEMS="$(tr ' ' '\n' <<<"${SELECTED_HUB_ITEMS}" | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  save_env
}

install_extra_hub_items() {
  load_env_if_exists
  [[ -n "${SELECTED_HUB_ITEMS:-}" ]] || return 0
  local entry item_type item_name
  for entry in ${SELECTED_HUB_ITEMS}; do
    item_type="${entry%%:*}"
    item_name="${entry#*:}"
    [[ -n "${item_type}" && -n "${item_name}" && "${item_type}" != "${item_name}" ]] || continue
    log "Hub ${item_type}: ${item_name}"
    cscli "${item_type}" install "${item_name}" || true
  done
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
  warn "Дополнительные sources/acquis для выбранных collections нужно проверить под конкретный сервис."
  warn "Скрипт не прописывает фейковые пути логов: Docker-сервисы часто пишут в journald/docker logs или свои volume."
  warn "После установки проверь рекомендации: sudo cscli collections inspect <collection>"
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
  echo "  Collections: ${SELECTED_COLLECTIONS:-crowdsecurity/linux crowdsecurity/sshd}"
  [[ -n "${SELECTED_HUB_ITEMS:-}" ]] && echo "  Дополнительные Hub elements: ${SELECTED_HUB_ITEMS}"
  echo "  Дополнительные источники логов: проверь через sudo cscli collections inspect <collection>"
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
  if tui_available; then
    tui_theme
    run_install_step "Устанавливаю базовые пакеты" install_base
    run_install_step "Удаляю Fail2Ban при наличии" remove_fail2ban_if_installed
    run_install_step "Подключаю репозиторий CrowdSec" install_crowdsec_repo
    run_install_step "Устанавливаю CrowdSec agent" install_crowdsec_agent
    select_hub_collections
    select_extra_hub_items
    run_install_step "Устанавливаю collections" install_collections
    run_install_step "Устанавливаю дополнительные Hub elements" install_extra_hub_items
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
    select_hub_collections
    select_extra_hub_items
    install_collections
    install_extra_hub_items
    configure_acquisition
    register_to_central_lapi
    configure_agent_as_node
    install_firewall_bouncer
    test_config
    restart_services
  fi
  if tui_available; then
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
