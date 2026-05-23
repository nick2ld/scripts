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
# - v0.2-secure: safer env parsing, UFW backup/SSH preservation, update confirmation, single-instance lock.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

UI_LANG="${UI_LANG:-}"

T() {
  if [[ "${UI_LANG:-ru}" == "en" ]]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

load_saved_language() {
  local env_file="${ENV_FILE:-}" line key value
  UI_LANG="${UI_LANG:-}"
  if [[ -n "${env_file}" && -f "${env_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]] && continue
      key="${line%%=*}"
      value="${line#*=}"
      if [[ "${key}" == "UI_LANG" ]]; then
        value="${value//\'/}"
        value="${value//\"/}"
        value="${value//\\ / }"
        case "${value}" in
          en|ru) UI_LANG="${value}" ;;
        esac
        break
      fi
    done < "${env_file}"
  fi
  case "${UI_LANG:-}" in
    en|ru) ;;
    *) UI_LANG="ru" ;;
  esac
}

save_language_only() {
  local env_file="${ENV_FILE:-}" tmp
  [[ -n "${env_file}" ]] || return 0
  mkdir -p "$(dirname "${env_file}")" 2>/dev/null || true
  if [[ -f "${env_file}" ]]; then
    tmp="$(mktemp)"
    grep -v '^UI_LANG=' "${env_file}" > "${tmp}" 2>/dev/null || true
    printf 'UI_LANG=%s\n' "${UI_LANG:-ru}" >> "${tmp}"
    cat "${tmp}" > "${env_file}"
    rm -f "${tmp}"
  else
    printf 'UI_LANG=%s\n' "${UI_LANG:-ru}" > "${env_file}"
  fi
  chmod 600 "${env_file}" 2>/dev/null || true
}

choose_language_if_needed() {
  load_saved_language
  if [[ -f "${ENV_FILE:-/nonexistent}" ]] && grep -q '^UI_LANG=' "${ENV_FILE}" 2>/dev/null && [[ -n "${UI_LANG:-}" ]]; then
    return 0
  fi
  if tui_available && [[ -t 0 && -t 1 ]]; then
    local choice
    tui_theme
    export CROWDSEC_TUI_MODE="${CROWDSEC_TUI_MODE:-installer}"
    choice="$(whiptail --backtitle "CrowdSec Central" --title " CrowdSec Central " --cancel-button "Exit" --ok-button "OK" --notags --menu "Choose interface language / Выберите язык интерфейса:" 14 88 2 \
      "ru" "Русский" \
      "en" "English" \
      3>&1 1>&2 2>&3)" || choice="ru"
    UI_LANG="${choice}"
  elif [[ -t 0 ]]; then
    echo "Choose interface language / Выберите язык интерфейса:"
    echo "1) Русский"
    echo "2) English"
    read -rp "Language [1/2]: " lang_choice || lang_choice="1"
    case "${lang_choice}" in
      2|en|EN|English|english) UI_LANG="en" ;;
      *) UI_LANG="ru" ;;
    esac
  else
    UI_LANG="ru"
  fi
  save_language_only
}

change_language() {
  load_saved_language
  local choice
  if tui_available && [[ -t 0 && -t 1 ]]; then
    tui_theme
    choice="$(whiptail --backtitle "CrowdSec Central" --title "$(T " Язык интерфейса " " Interface language ")" --cancel-button "$(T "Назад" "Back")" --ok-button "OK" --notags --menu "$(T "Выберите язык интерфейса:" "Choose interface language:")" 14 88 2 \
      "ru" "Русский" \
      "en" "English" \
      3>&1 1>&2 2>&3)" || return 0
    UI_LANG="${choice}"
  else
    echo
    echo "1) Русский"
    echo "2) English"
    read -rp "$(T "Выберите язык [1/2]: " "Choose language [1/2]: ")" choice || return 0
    case "${choice}" in
      2|en|EN|English|english) UI_LANG="en" ;;
      *) UI_LANG="ru" ;;
    esac
  fi
  save_language_only
  if tui_available && [[ -t 0 && -t 1 ]]; then
    whiptail --backtitle "CrowdSec Central" --title "$(T " Готово " " Done ")" --msgbox "$(T "Язык сохранён." "Language saved.")" 8 70 || true
  else
    echo "$(T "Язык сохранён." "Language saved.")"
  fi
}


CONFIG_DIR="/root/crowdsec-central"
ENV_FILE="${CONFIG_DIR}/central.env"
CONNECTIONS_FILE="${CONFIG_DIR}/vps-connections.tsv"
COMPOSE_DIR="/opt/crowdsec-web-ui"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
MANAGER_COMPOSE_DIR="/opt/crowdsec-manager"
MANAGER_COMPOSE_FILE="${MANAGER_COMPOSE_DIR}/docker-compose.yml"
INSTALLED_SCRIPT="/usr/local/sbin/crowdsec-central-menu"
PROFILE_FILE="/etc/profile.d/crowdsec-central-menu.sh"
LOCK_FILE="/tmp/crowdsec-central-menu.lock"
DEFAULT_WEB_PORT="3000"
DEFAULT_LAPI_PORT="8080"
LOCAL_LAPI_ALLOWED_RANGES="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
WEBUI_IMAGE="ghcr.io/theduffman85/crowdsec-web-ui:latest"
MANAGER_IMAGE="hhftechnology/crowdsec-manager:independent"
SCRIPT_VERSION="v0.7.0-i18n-protection-menu"
SCRIPT_RELEASE_DATE="2026-05-23"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/central.sh"
VPS_SCRIPT_RAW_URL="https://github.com/nick2ld/scripts/raw/refs/heads/main/crowdsec/vps.sh"
SYSLOG_DEVICES_FILE="${CONFIG_DIR}/bouncer-syslog-devices.tsv"
REMOTE_SYSLOG_DIR="/var/log/crowdsec-remote"
REMOTE_SYSLOG_DIAG_DIR="/var/log/crowdsec-remote-diagnostic"
DEFAULT_REMOTE_SYSLOG_PORT="5140"
TRUSTED_IP_FILE="${CONFIG_DIR}/trusted-ip-allowlist.tsv"

log() { echo "==> $*"; }
ok() { echo "$(T "ГОТОВО" "OK"): $*"; }
warn() { echo "$(T "ВНИМАНИЕ" "WARN"): $*"; }
fail() { echo "$(T "ОШИБКА" "ERROR"): $*" >&2; exit 1; }
pause() {
  if [[ "${CROWDSEC_TUI_MODE:-}" != "whiptail" && "${CROWDSEC_TUI_MODE:-}" != "installer" ]]; then
    echo
    read -rp "$(T "Нажми Enter для продолжения..." "Press Enter to continue...")" _ || true
  fi
}
is_interactive() { [[ -t 0 ]]; }
has_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }
is_tui_session() { [[ -n "${CROWDSEC_TUI_MODE:-}" && -t 1 && -r /dev/tty ]]; }
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
    fail "Интерактивная установка не работает через pipe. Запусти так: sh -c 'tmp=\"\$(mktemp -t crowdsec-central.XXXXXX)\" && curl -fsSL \"https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/central.sh\" -o \"\$tmp\" && if [ \"\$(id -u)\" -eq 0 ]; then bash \"\$tmp\"; else sudo bash \"\$tmp\"; fi; rc=\$?; rm -f \"\$tmp\"; exit \"\$rc\"'"
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

progress_clean_tail() {
  local file="$1"
  if [[ -s "${file}" ]]; then
    tail -n 12 "${file}" 2>/dev/null \
      | sed -E $'s/\x1b\\[[0-9;?]*[ -/]*[@-~]//g; s/\r/ /g; s/XXX/X X X/g' \
      | cut -c 1-100
  else
    printf '%s\n' "ожидание вывода команды..."
  fi
}

run_with_live_progress() {
  local title="$1"
  shift
  local log_file rc_file rc pct tail_text
  log_file="$(mktemp)"
  rc_file="$(mktemp)"

  if [[ "${CROWDSEC_TUI_MODE:-}" =~ ^(whiptail|installer)$ && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]] && tui_available; then
    set +e
    (
      set +e
      set +E
      trap - ERR
      export CROWDSEC_PROGRESS_ACTIVE=1
      "$@" >"${log_file}" 2>&1 &
      local pid=$!
      local pct=2
      local tail_text=""
      while kill -0 "${pid}" 2>/dev/null; do
        tail_text="$(progress_clean_tail "${log_file}")"
        pct=$((pct + 2))
        (( pct > 96 )) && pct=12
        printf 'XXX\n%s\n%s\n\n%s\nXXX\n' "${pct}" "${title}" "${tail_text}"
        sleep 1
      done
      wait "${pid}"
      local inner_rc=$?
      printf '%s' "${inner_rc}" >"${rc_file}"
      if [[ "${inner_rc}" -eq 0 ]]; then
        tail_text="$(progress_clean_tail "${log_file}")"
        printf 'XXX\n100\n%s\n\n%s\nXXX\n' "${title} завершено" "${tail_text}"
        sleep 0.2
      fi
      exit 0
    ) | whiptail --title " ${title} " --gauge "${title}" 22 100 0
    rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      rm -f "${log_file}" "${rc_file}"
      return 0
    fi
    whiptail --title " Ошибка: ${title} " --textbox "${log_file}" 30 120 || true
    rm -f "${log_file}" "${rc_file}"
    return "${rc}"
  fi

  log "${title}..."
  set +e
  (
    set +e
    set +E
    trap - ERR
    export CROWDSEC_PROGRESS_ACTIVE=1
    "$@"
  ) >"${log_file}" 2>&1 &
  local pid=$!
  if [[ -t 1 ]]; then
    local spin='|/-\\'
    local i=0
    while kill -0 "${pid}" 2>/dev/null; do
      tail_text="$(tail -n 1 "${log_file}" 2>/dev/null | tr '\r' ' ' | cut -c 1-100)"
      printf '\r[%s] %s: %s' "${spin:i++%${#spin}:1}" "${title}" "${tail_text:-выполняется}"
      sleep 1
    done
    printf '\r%*s\r' 120 ''
  fi
  wait "${pid}"
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    rm -f "${log_file}" "${rc_file}"
    ok "${title} завершено."
    return 0
  fi
  cat "${log_file}" >&2
  rm -f "${log_file}" "${rc_file}"
  return "${rc}"
}


run_menu_step() {
  local title="$1"
  shift
  if run_with_live_progress "${title}" "$@"; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
      whiptail --title " Успех " --msgbox "${title} успешно завершено." 8 78
    fi
    return 0
  fi
  if [[ "${CROWDSEC_TUI_MODE:-}" != "whiptail" ]]; then
    warn "${title} завершилось с ошибкой."
  fi
  return 1
}


show_file() {
  local title="$1"
  local tmp="$2"
  if is_tui_session; then
    if [[ "${CROWDSEC_TUI_MODE}" =~ ^(whiptail|installer)$ ]] && tui_available; then
      whiptail --title " ${title} " --textbox "${tmp}" 30 110 </dev/tty >/dev/tty 2>&1 || true
    elif command -v less >/dev/null 2>&1; then
      safe_clear
      LESS='-R' less "${tmp}" </dev/tty >/dev/tty || true
    else
      safe_clear
      printf '%s\n\n' "${title}" >/dev/tty
      cat "${tmp}" >/dev/tty
      read -rp "$(T "Нажми Enter для продолжения..." "Press Enter to continue...")" _ </dev/tty || true
    fi
  else
    safe_clear
    if has_tty; then
      printf '%s\n\n' "${title}" >/dev/tty
      cat "${tmp}" >/dev/tty
      read -rp "$(T "Нажми Enter для продолжения..." "Press Enter to continue...")" _ </dev/tty || true
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


acquire_script_lock() {
  exec 9>"${LOCK_FILE}"
  if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9 2>/dev/null; then
      fail "Уже запущен другой экземпляр CrowdSec Central menu. Если это ошибка, проверь: ${LOCK_FILE}"
    fi
    return 0
  fi
  # Fallback для минимальных контейнеров без flock.
  if ! mkdir "${LOCK_FILE}.dir" 2>/dev/null; then
    fail "Уже запущен другой экземпляр CrowdSec Central menu. Если это ошибка, удали: ${LOCK_FILE}.dir"
  fi
  trap 'rm -rf "${LOCK_FILE}.dir"; cleanup_runtime_files' EXIT
}

cleanup_runtime_files() {
  # Зарезервировано для будущей очистки общих временных ресурсов.
  true
}

trap cleanup_runtime_files EXIT

read_env_key() {
  local key="$1" value=""
  [[ -f "${ENV_FILE}" ]] || return 0
  while IFS='=' read -r k v; do
    [[ -n "${k:-}" ]] || continue
    [[ "${k}" == \#* ]] && continue
    if [[ "${k}" == "${key}" ]]; then
      value="${v//$'\r'/}"
      printf '%s' "${value}"
      return 0
    fi
  done < "${ENV_FILE}"
}

sanitize_token_value() {
  printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._:@/%+=,-'
}

sanitize_plain_value() {
  printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._:@/%+=, -'
}

get_sshd_ports() {
  local ports=() file port
  for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "${file}" ]] || continue
    while read -r _ port _; do
      [[ "${port:-}" =~ ^[0-9]+$ ]] || continue
      ports+=("${port}")
    done < <(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "${file}" 2>/dev/null || true)
  done
  ports+=("22")
  printf '%s\n' "${ports[@]}" | awk '!seen[$0]++'
}

backup_ufw_state() {
  local backup_dir="${CONFIG_DIR}/ufw-backup-$(date +%F-%H%M%S)"
  mkdir -p "${backup_dir}"
  chmod 700 "${backup_dir}"
  ufw status verbose >"${backup_dir}/ufw-status-before.txt" 2>&1 || true
  [[ -d /etc/ufw ]] && cp -a /etc/ufw "${backup_dir}/etc-ufw" 2>/dev/null || true
  echo "${backup_dir}"
}

confirm_dangerous_action() {
  local title="$1" text="$2"
  if [[ "${CROWDSEC_ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${CROWDSEC_TUI_MODE:-}" =~ ^(whiptail|installer)$ ]] && tui_available; then
    whiptail --title " ${title} " --yes-button "$(T "Продолжить" "Continue")" --no-button "$(T "Отмена" "Cancel")" --yesno "${text}" 14 88
    return $?
  fi
  if has_tty; then
    echo
    echo "${title}"
    echo "${text}"
    read -rp "Продолжить? [y/N]: " ans </dev/tty || return 1
    [[ "${ans:-N}" =~ ^[Yy]$ ]]
    return $?
  fi
  return 1
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
  # Безопасно читаем central.env как данные, а не как shell-код.
  # Старый вариант `source central.env` мог выполнить произвольную команду от root,
  # если файл был повреждён или изменён злоумышленником.
  local env_lan env_web env_lapi env_public env_ranges env_token env_bouncer env_pass env_type env_public_lapi_url env_public_lapi_mode env_npm_cidr env_ui_lang
  env_lan="$(read_env_key LAN_IP)"
  env_web="$(read_env_key WEB_PORT)"
  env_lapi="$(read_env_key LAPI_PORT)"
  env_public="$(read_env_key PUBLIC_ADDR)"
  env_ranges="$(read_env_key ALLOWED_RANGES)"
  env_token="$(read_env_key AUTO_REG_TOKEN)"
  env_bouncer="$(read_env_key SHARED_BOUNCER_KEY)"
  env_pass="$(read_env_key WEBUI_PASSWORD)"
  env_type="$(read_env_key WEB_UI_TYPE)"
  env_public_lapi_url="$(read_env_key PUBLIC_LAPI_URL)"
  env_public_lapi_mode="$(read_env_key PUBLIC_LAPI_MODE)"
  env_npm_cidr="$(read_env_key NPM_ALLOWED_CIDR)"
  env_ui_lang="$(read_env_key UI_LANG)"

  LAN_IP="${LAN_IP:-${env_lan:-$(get_lan_ip)}}"
  WEB_PORT="${WEB_PORT:-${env_web:-${DEFAULT_WEB_PORT}}}"
  LAPI_PORT="${LAPI_PORT:-${env_lapi:-${DEFAULT_LAPI_PORT}}}"
  PUBLIC_ADDR="${PUBLIC_ADDR:-${env_public:-}}"
  ALLOWED_RANGES="${ALLOWED_RANGES:-${env_ranges:-}}"
  AUTO_REG_TOKEN="${AUTO_REG_TOKEN:-${env_token:-}}"
  SHARED_BOUNCER_KEY="${SHARED_BOUNCER_KEY:-${env_bouncer:-}}"
  WEBUI_PASSWORD="${WEBUI_PASSWORD:-${env_pass:-}}"
  WEB_UI_TYPE="${WEB_UI_TYPE:-${env_type:-manager}}"
  PUBLIC_LAPI_URL="${PUBLIC_LAPI_URL:-${env_public_lapi_url:-}}"
  PUBLIC_LAPI_MODE="${PUBLIC_LAPI_MODE:-${env_public_lapi_mode:-direct}}"
  NPM_ALLOWED_CIDR="${NPM_ALLOWED_CIDR:-${env_npm_cidr:-}}"
  UI_LANG="${UI_LANG:-${env_ui_lang:-ru}}"

  LAN_IP="$(sanitize_plain_value "${LAN_IP}")"
  PUBLIC_ADDR="$(sanitize_plain_value "${PUBLIC_ADDR}")"
  PUBLIC_LAPI_URL="$(sanitize_token_value "${PUBLIC_LAPI_URL}")"
  PUBLIC_LAPI_MODE="$(sanitize_plain_value "${PUBLIC_LAPI_MODE}")"
  NPM_ALLOWED_CIDR="$(printf '%s' "${NPM_ALLOWED_CIDR}" | tr -cd '0-9A-Fa-f:.\/')"
  case "${UI_LANG:-ru}" in en|ru) ;; *) UI_LANG="ru" ;; esac
  AUTO_REG_TOKEN="$(sanitize_token_value "${AUTO_REG_TOKEN}")"
  SHARED_BOUNCER_KEY="$(sanitize_token_value "${SHARED_BOUNCER_KEY}")"
  WEBUI_PASSWORD="$(sanitize_token_value "${WEBUI_PASSWORD}")"
  WEB_UI_TYPE="$(sanitize_plain_value "${WEB_UI_TYPE}")"

  if ! is_valid_port "${WEB_PORT}"; then
    WEB_PORT="${DEFAULT_WEB_PORT}"
  fi
  if ! is_valid_port "${LAPI_PORT}"; then
    LAPI_PORT="${DEFAULT_LAPI_PORT}"
  fi
  if [[ -z "${LAN_IP}" ]]; then
    LAN_IP="127.0.0.1"
  fi

  RAW_RANGES="${ALLOWED_RANGES}" ALLOWED_RANGES="$(RAW_RANGES="${ALLOWED_RANGES}" sanitize_ranges)"

  LOCAL_WEB_UI="http://${LAN_IP}:${WEB_PORT}"
  LOCAL_LAPI_URL="http://${LAN_IP}:${LAPI_PORT}"
  if [[ -n "${PUBLIC_LAPI_URL:-}" && "${PUBLIC_LAPI_URL}" =~ ^https?://[^[:space:]]+$ ]]; then
    VPS_LAPI_URL="${PUBLIC_LAPI_URL%/}"
  elif [[ -n "${PUBLIC_ADDR}" ]]; then
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
  WEB_UI_TYPE="manager"
  PUBLIC_LAPI_URL="${PUBLIC_LAPI_URL:-}"
  PUBLIC_LAPI_MODE="${PUBLIC_LAPI_MODE:-direct}"
  NPM_ALLOWED_CIDR="${NPM_ALLOWED_CIDR:-}"
  UI_LANG="${UI_LANG:-ru}"

  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"

  [[ -n "${AUTO_REG_TOKEN:-}" ]] || AUTO_REG_TOKEN="$(openssl rand -hex 32)"
  [[ -n "${SHARED_BOUNCER_KEY:-}" ]] || SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"
  [[ -n "${WEBUI_PASSWORD:-}" ]] || WEBUI_PASSWORD="$(openssl rand -hex 24)"

  RAW_RANGES="${ALLOWED_RANGES:-}" ALLOWED_RANGES="$(RAW_RANGES="${ALLOWED_RANGES:-}" sanitize_ranges)"

  PUBLIC_LAPI_URL="$(sanitize_token_value "${PUBLIC_LAPI_URL}")"
  PUBLIC_LAPI_MODE="$(sanitize_plain_value "${PUBLIC_LAPI_MODE}")"
  NPM_ALLOWED_CIDR="$(printf '%s' "${NPM_ALLOWED_CIDR}" | tr -cd '0-9A-Fa-f:.\/')"

  LOCAL_WEB_UI="http://${LAN_IP}:${WEB_PORT}"
  LOCAL_LAPI_URL="http://${LAN_IP}:${LAPI_PORT}"
  if [[ -n "${PUBLIC_LAPI_URL:-}" && "${PUBLIC_LAPI_URL}" =~ ^https?://[^[:space:]]+$ ]]; then
    VPS_LAPI_URL="${PUBLIC_LAPI_URL%/}"
  elif [[ -n "${PUBLIC_ADDR:-}" ]]; then
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
PUBLIC_LAPI_MODE=${PUBLIC_LAPI_MODE}
PUBLIC_LAPI_URL=${PUBLIC_LAPI_URL}
NPM_ALLOWED_CIDR=${NPM_ALLOWED_CIDR}
UI_LANG=${UI_LANG}
ENV
  chmod 600 "${ENV_FILE}"
}

print_header() {
  safe_clear
  echo "============================================================"
  echo "CrowdSec Central LAPI + Web UI (${SCRIPT_VERSION}, ${SCRIPT_RELEASE_DATE})"
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
  if [[ -n "${PUBLIC_LAPI_URL:-}" ]]; then
    echo "  режим: ${PUBLIC_LAPI_MODE:-direct}"
  fi
  echo
  echo "Файл настроек:"
  echo "  ${ENV_FILE}"
  echo
}

upgrade_system_packages() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    local fifo
    fifo=$(mktemp -u)
    mkfifo "${fifo}"

    whiptail --title " Обновление ОС " --gauge "Синхронизация списков пакетов (apt update)..." 8 78 0 < "${fifo}" &
    local gauge_pid=$!
    exec 3> "${fifo}"

    export DEBIAN_FRONTEND=noninteractive

    echo -e "XXX\n30\nСкачивание метаданных и проверка обновлений...\nXXX" >&3
    apt-get update -y >/dev/null 2>&1

    echo -e "XXX\n60\nУстановка системных обновлений. Пожалуйста, подождите...\nXXX" >&3
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" >/dev/null 2>&1

    echo -e "XXX\n90\nОчистка кэша пакетов и удаление лишних зависимостей...\nXXX" >&3
    apt-get autoremove -y >/dev/null 2>&1
    apt-get autoclean -y >/dev/null 2>&1

    echo -e "XXX\n100\nВсе компоненты ОС успешно обновлены!\nXXX" >&3
    sleep 0.2

    exec 3>&-
    wait "${gauge_pid}" 2>/dev/null || true
    rm -f "${fifo}"
    
    whiptail --title " Успех " --msgbox "Пакеты операционной системы обновлены." 8 78
  else
    log "Обновляю пакеты ОС (apt update && apt upgrade)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    apt-get autoremove -y
    apt-get autoclean -y
    ok "Пакеты ОС обновлены."
  fi
}

install_base() {
  log "Устанавливаю базовые пакеты..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg lsb-release apt-transport-https openssl python3 python3-yaml sudo ufw nano jq iproute2 procps xz-utils dialog whiptail less
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
  command -v curl >/dev/null 2>&1 || fail "Не найден curl. Установи curl перед настройкой репозитория CrowdSec."
  local tmp
  tmp="$(mktemp)"
  curl -fsSL https://install.crowdsec.net -o "${tmp}"
  bash -n "${tmp}"
  if [[ "${CROWDSEC_ASSUME_YES:-0}" != "1" ]]; then
    confirm_dangerous_action "Удалённый установщик CrowdSec" "Скрипт скачал официальный install.crowdsec.net во временный файл и проверил синтаксис. Следующий шаг выполнит этот файл от root для настройки apt-репозитория CrowdSec. Это безопаснее, чем curl | sh, но всё равно остаётся выполнением удалённого кода."
  fi
  bash "${tmp}"
  rm -f "${tmp}"
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
  echo "Внешний адрес нужен для готовой команды подключения VPS. Можно оставить пустым."
  echo "Если LAPI будет доступен через Nginx Proxy Manager, ниже можно указать полный HTTPS URL."
  prompt_default input_public_lapi_url "Публичный HTTPS URL LAPI через NPM [можно пусто, пример https://lapi.example.com]: " "${PUBLIC_LAPI_URL:-}"
  PUBLIC_LAPI_URL="${input_public_lapi_url:-${PUBLIC_LAPI_URL:-}}"
  if [[ -n "${PUBLIC_LAPI_URL}" ]]; then
    PUBLIC_LAPI_MODE="npm"
    PUBLIC_ADDR=""
    prompt_default input_npm_cidr "IP/CIDR Nginx Proxy Manager для доступа к LAPI [можно пусто]: " "${NPM_ALLOWED_CIDR:-}"
    NPM_ALLOWED_CIDR="${input_npm_cidr:-${NPM_ALLOWED_CIDR:-}}"
    if [[ -n "${NPM_ALLOWED_CIDR}" && ! ",${ALLOWED_RANGES}," =~ ,${NPM_ALLOWED_CIDR}, ]]; then
      ALLOWED_RANGES="${ALLOWED_RANGES:+${ALLOWED_RANGES},}${NPM_ALLOWED_CIDR}"
    fi
  else
    PUBLIC_LAPI_MODE="direct"
    prompt_default input_public "Внешний адрес для удалённых серверов [можно пусто]: " "${PUBLIC_ADDR:-}"
    PUBLIC_ADDR="${input_public:-${PUBLIC_ADDR:-}}"
  fi
  WEB_UI_TYPE="manager"
  [[ -n "${AUTO_REG_TOKEN:-}" ]] || AUTO_REG_TOKEN="$(openssl rand -hex 32)"
  [[ -n "${SHARED_BOUNCER_KEY:-}" ]] || SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"
  [[ -n "${WEBUI_PASSWORD:-}" ]] || WEBUI_PASSWORD="$(openssl rand -hex 24)"
  save_env
}

bootstrap_installer_tui() {
  type -P dialog >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || return 1
  safe_clear
  echo "Подготовка интерактивного установщика..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/tmp/crowdsec-menu-bootstrap.log 2>&1 || return 1
  apt-get install -y dialog whiptail >>/tmp/crowdsec-menu-bootstrap.log 2>&1 || return 1
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
  whiptail --title " ${title} " --yes-button "$(T "Да" "Yes")" --no-button "$(T "Нет" "No")" --yesno "${text}" 10 78
}

ask_initial_settings_tui() {
  safe_source_env
  DETECTED_IP="$(get_lan_ip)"
  [[ -n "${DETECTED_IP}" ]] || DETECTED_IP="${LAN_IP}"

  LAN_IP="$(tui_input "$(T "Начальная настройка" "Initial setup")" "LAN IP для Web UI и локального LAPI" "${DETECTED_IP}")" || exit 1
  WEB_PORT="$(tui_input "$(T "Начальная настройка" "Initial setup")" "$(T "Порт Web UI" "Web UI port")" "${WEB_PORT:-3000}")" || exit 1
  LAPI_PORT="$(tui_input "$(T "Начальная настройка" "Initial setup")" "$(T "Порт центрального LAPI" "Central LAPI port")" "${LAPI_PORT:-8080}")" || exit 1
  PUBLIC_LAPI_URL="$(tui_input "$(T "Публичный LAPI" "Public LAPI")" "Публичный HTTPS URL LAPI через Nginx Proxy Manager.\n\nПример: https://lapi.example.com\n\nЕсли NPM не используется, оставь пустым." "${PUBLIC_LAPI_URL:-}")" || exit 1
  if [[ -n "${PUBLIC_LAPI_URL:-}" ]]; then
    PUBLIC_LAPI_MODE="npm"
    PUBLIC_ADDR=""
    NPM_ALLOWED_CIDR="$(tui_input "Nginx Proxy Manager" "IP/CIDR Nginx Proxy Manager, которому разрешить доступ к LAPI.\n\nМожно оставить пустым, если доступ уже разрешён локальной сетью." "${NPM_ALLOWED_CIDR:-}")" || exit 1
    if [[ -n "${NPM_ALLOWED_CIDR:-}" && ! ",${ALLOWED_RANGES}," =~ ,${NPM_ALLOWED_CIDR}, ]]; then
      ALLOWED_RANGES="${ALLOWED_RANGES:+${ALLOWED_RANGES},}${NPM_ALLOWED_CIDR}"
    fi
  else
    PUBLIC_LAPI_MODE="direct"
    PUBLIC_ADDR="$(tui_input "$(T "Внешний адрес" "Public address")" "Внешний IP или DDNS для готовой команды подключения VPS. Можно оставить пустым." "${PUBLIC_ADDR:-}")" || exit 1
  fi
  WEB_UI_TYPE="manager"

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


shell_quote() {
  printf '%q' "${1:-}"
}

create_named_vps_bouncer_key() {
  safe_source_env
  local mode rc
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    set +e
    mode="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" \
      --title " $(T "Добавление VPS" "Add VPS") " \
      --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags \
      --menu "$(T "Выбери способ подключения:\n\n1. Удалённая VPS - central подключится к VPS по SSH, сам запустит установку и потом выполнит validate.\n2. Ручная VPS - как раньше: central покажет данные, а vps.sh запускается вручную на VPS.\n3. Устройство только с bouncer/API - роутер, OpenWrt или другой хост без CrowdSec agent: central создаст bouncer key и покажет настройки." "Choose connection type:\n\n1. Remote VPS - central connects over SSH, runs the installation, and then validates the machine.\n2. Manual VPS - old behavior: central shows values and vps.sh is run manually on the VPS.\n3. Bouncer-only/API device - router, OpenWrt or another host without CrowdSec agent: central creates a bouncer key and shows settings.")" \
      21 100 3 \
      "remote" "$(T "VPS: подключиться по SSH и установить автоматически" "VPS: connect over SSH and install automatically")" \
      "manual" "$(T "VPS: ручное добавление с ожиданием регистрации" "VPS: manual setup with registration wait")" \
      "openwrt" "$(T "Устройство с bouncer/API: добавить bouncer key" "Bouncer/API device: add bouncer key")" \
      3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0
  else
    echo
    echo "$(T "Способ добавления:" "Add mode:")"
    echo "1) $(T "VPS: подключиться по SSH и установить автоматически" "VPS: connect over SSH and install automatically")"
    echo "2) $(T "VPS: ручное добавление с ожиданием регистрации" "VPS: manual setup with registration wait")"
    echo "3) $(T "Устройство с bouncer/API: добавить bouncer key" "Bouncer/API device: add bouncer key")"
    read -rp "$(T "Выбор [1/2/3]: " "Choice [1/2/3]: ")" mode || return 0
    case "${mode}" in
      1|remote) mode="remote" ;;
      3|openwrt|router|bouncer|device) mode="openwrt" ;;
      *) mode="manual" ;;
    esac
  fi

  case "${mode}" in
    remote) create_named_vps_remote_install ;;
    manual) create_named_vps_bouncer_key_manual ;;
    openwrt) create_openwrt_bouncer_connection ;;
    *) return 0 ;;
  esac
}

create_vps_connection_apply_common() {
  echo "Удаление старого bouncer: ${node_name}"
  if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
    docker exec crowdsec cscli bouncers delete "${node_name}" || true
    echo "Регистрация нового bouncer в Docker LAPI: ${node_name}"
    docker exec crowdsec cscli bouncers add "${node_name}" --key "${bouncer_key}"
  else
    cscli bouncers delete "${node_name}" || true
    echo "Регистрация нового bouncer в локальном LAPI: ${node_name}"
    cscli bouncers add "${node_name}" --key "${bouncer_key}"
  fi

  echo "Сохранение central.env"
  save_env

  echo "Обновление config.yaml CrowdSec LAPI"
  configure_docker_crowdsec_lapi

  echo "Перезапуск контейнера CrowdSec"
  (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)

  echo "Обновление правил UFW"
  configure_ufw_full

  echo "Запись подключения в ${CONNECTIONS_FILE}"
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"
  touch "${CONNECTIONS_FILE}"
  chmod 600 "${CONNECTIONS_FILE}"
  awk -F'\t' -v name="${node_name}" '($2 != name)' "${CONNECTIONS_FILE}" >"${CONNECTIONS_FILE}.tmp" || true
  mv "${CONNECTIONS_FILE}.tmp" "${CONNECTIONS_FILE}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "${node_name}" "${vps_ip}" "${VPS_LAPI_URL}" "${AUTO_REG_TOKEN}" "${bouncer_key}" >>"${CONNECTIONS_FILE}"
}

ensure_remote_ssh_tools() {
  if command -v ssh >/dev/null 2>&1 && command -v sshpass >/dev/null 2>&1; then
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y openssh-client sshpass
}

build_remote_vps_installer_script() {
  local out="$1"
  cat > "${out}" <<REMOTE
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export TERM="${TERM:-xterm}"
export CROWDSEC_VPS_UNATTENDED=1

mkdir -p /root/crowdsec-vps-node
chmod 700 /root/crowdsec-vps-node

cat > /root/crowdsec-vps-node/node.env <<ENV
CENTRAL_LAPI_URL=$(shell_quote "${VPS_LAPI_URL}")
AUTO_REG_TOKEN=$(shell_quote "${AUTO_REG_TOKEN}")
SHARED_BOUNCER_KEY=$(shell_quote "${bouncer_key}")
MACHINE_NAME=$(shell_quote "${node_name}")
INSTALL_FIREWALL_BOUNCER=yes
REMOVE_FAIL2BAN=yes
COLLECTION_SELECTION_MODE=$(shell_quote "${remote_collection_mode:-auto}")
SELECTED_COLLECTIONS=$(shell_quote "${remote_selected_collections:-}")
HUB_ITEM_SELECTION_MODE=none
SELECTED_HUB_ITEMS=
FIREWALL_BOUNCER_PACKAGE=
FIREWALL_BOUNCER_MODE=
UI_LANG=$(shell_quote "${UI_LANG:-ru}")
ENV
chmod 600 /root/crowdsec-vps-node/node.env

if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl ca-certificates
fi

curl -fsSL "$(shell_quote "${VPS_SCRIPT_RAW_URL}")" -o /root/crowdsec-vps-node/vps.sh
chmod 700 /root/crowdsec-vps-node/vps.sh
if ! grep -q -- '--unattended' /root/crowdsec-vps-node/vps.sh && ! grep -q 'CROWDSEC_VPS_UNATTENDED' /root/crowdsec-vps-node/vps.sh; then
  echo "ERROR: downloaded vps.sh does not support unattended mode. Update crowdsec/vps.sh in the GitHub repository first." >&2
  exit 90
fi
TERM=xterm CROWDSEC_VPS_UNATTENDED=1 bash /root/crowdsec-vps-node/vps.sh --unattended
REMOTE
  chmod 600 "${out}"
}

remote_ssh_base() {
  SSHPASS="${ssh_password}" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/root/.ssh/known_hosts \
    -o ConnectTimeout=20 \
    -p "${ssh_port}" \
    "${ssh_user}@${ssh_host}" "$@"
}

remote_upload_runner() {
  local runner="$1"
  remote_ssh_base "cat > /tmp/crowdsec-vps-remote-install.sh && chmod 700 /tmp/crowdsec-vps-remote-install.sh" < "${runner}"
}

remote_run_runner() {
  if [[ "${ssh_user}" == "root" ]]; then
    remote_ssh_base "bash /tmp/crowdsec-vps-remote-install.sh"
  else
    printf '%s\n' "${ssh_password}" | remote_ssh_base "sudo -S -p '' bash /tmp/crowdsec-vps-remote-install.sh"
  fi
}

remote_restart_vps_services_after_validate() {
  local cmd
  cmd="systemctl reset-failed crowdsec || true; systemctl restart crowdsec; systemctl restart crowdsec-firewall-bouncer || true; systemctl status crowdsec --no-pager -l || true; cscli lapi status || true"
  if [[ "${ssh_user}" == "root" ]]; then
    remote_ssh_base "${cmd}"
  else
    printf '%s\n' "${ssh_password}" | remote_ssh_base "sudo -S -p '' bash -lc $(shell_quote "${cmd}")"
  fi
}

create_named_vps_remote_install() {
  safe_source_env
  local rc tmp summary
  local node_name_raw vps_ip_raw ssh_host_raw ssh_port_raw ssh_user_raw ssh_password_raw remote_collection_mode_raw
  local vps_cidr runner

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    set +e
    node_name_raw="$(whiptail --title " $(T "Удалённая установка VPS" "Remote VPS installation") " --inputbox "$(T "Имя VPS.\n\nЭто же имя будет использовано как Machine name и bouncer name." "VPS name.\n\nThe same value will be used as Machine name and bouncer name.")" 12 92 "" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    set +e
    vps_ip_raw="$(whiptail --title " $(T "Удалённая установка VPS" "Remote VPS installation") " --inputbox "$(T "Внешний IP VPS, которому разрешить доступ к LAPI.\n\nСкрипт добавит его как /32 в LAPI и UFW." "Public VPS IP allowed to access LAPI.\n\nThe script will add it as /32 to LAPI and UFW.")" 12 92 "" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    set +e
    ssh_host_raw="$(whiptail --title " SSH " --inputbox "$(T "IP или hostname для SSH-подключения к VPS." "IP or hostname for SSH connection to the VPS.")" 10 92 "${vps_ip_raw}" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    set +e
    ssh_port_raw="$(whiptail --title " SSH " --inputbox "$(T "SSH порт" "SSH port")" 10 70 "22" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    set +e
    ssh_user_raw="$(whiptail --title " SSH " --inputbox "$(T "SSH логин.\n\nЛучше root. Если не root, у пользователя должен быть sudo." "SSH login.\n\nRoot is recommended. If not root, the user must have sudo.")" 12 80 "root" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    set +e
    ssh_password_raw="$(whiptail --title " SSH " --passwordbox "$(T "SSH пароль.\n\nПароль не сохраняется в central.env." "SSH password.\n\nThe password is not saved in central.env.")" 11 80 "" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    set +e
    remote_collection_mode_raw="$(whiptail --title " $(T "Collections VPS" "VPS collections") "       --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags       --menu "$(T "Как ставить CrowdSec collections на удалённой VPS?\n\nАвтоопределение проверит установленные сервисы на VPS и поставит базовые collections плюс подходящие для найденного софта. Это рекомендуемый режим для установки через SSH." "How to install CrowdSec collections on the remote VPS?\n\nAuto-detect checks installed services on the VPS and installs base collections plus matches for detected software. This is recommended for SSH installation.")"       18 96 2       "auto" "$(T "Автоопределить сервисы и поставить подходящие collections" "Auto-detect services and install matching collections")"       "base" "$(T "Поставить только базовые linux + sshd" "Install only base linux + sshd")"       3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    summary="$(T "Central подключится к VPS по SSH и выполнит установку CrowdSec node.\n\nНа VPS будут установлены пакеты, CrowdSec agent, firewall-bouncer и collections в выбранном режиме.\nFail2Ban будет удалён с backup, если найден.\n\nПродолжить?" "Central will connect to the VPS over SSH and install the CrowdSec node.\n\nThe VPS will get packages, CrowdSec agent, firewall-bouncer and collections in the selected mode.\nFail2Ban will be removed with backup if found.\n\nContinue?")"
    whiptail --title " $(T "Подтверждение" "Confirmation") " --yes-button "$(T "Продолжить" "Continue")" --no-button "$(T "Отмена" "Cancel")" --yesno "${summary}" 16 92 || return 0
  else
    read -rp "$(T "Имя VPS/Machine name: " "VPS/Machine name: ")" node_name_raw || return 0
    read -rp "$(T "Внешний IP VPS для LAPI: " "Public VPS IP for LAPI: ")" vps_ip_raw || return 0
    read -rp "$(T "SSH host [${vps_ip_raw}]: " "SSH host [${vps_ip_raw}]: ")" ssh_host_raw || return 0
    ssh_host_raw="${ssh_host_raw:-${vps_ip_raw}}"
    read -rp "$(T "SSH порт [22]: " "SSH port [22]: ")" ssh_port_raw || return 0
    ssh_port_raw="${ssh_port_raw:-22}"
    read -rp "$(T "SSH логин [root]: " "SSH login [root]: ")" ssh_user_raw || return 0
    ssh_user_raw="${ssh_user_raw:-root}"
    read -rsp "$(T "SSH пароль: " "SSH password: ")" ssh_password_raw || return 0
    echo
    echo "$(T "Collections на удалённой VPS:" "Collections on remote VPS:")"
    echo "1) $(T "Автоопределить сервисы и поставить подходящие collections" "Auto-detect services and install matching collections")"
    echo "2) $(T "Поставить только базовые linux + sshd" "Install only base linux + sshd")"
    read -rp "$(T "Выбор [1/2]: " "Choice [1/2]: ")" remote_collection_mode_raw || return 0
    case "${remote_collection_mode_raw}" in
      2|base) remote_collection_mode_raw="base" ;;
      *) remote_collection_mode_raw="auto" ;;
    esac
  fi

  node_name="$(printf '%s' "${node_name_raw:-}" | tr -cd 'A-Za-z0-9._:-')"
  vps_ip="$(printf '%s' "${vps_ip_raw:-}" | tr -cd '0-9A-Fa-f:.')"
  ssh_host="$(printf '%s' "${ssh_host_raw:-}" | tr -cd 'A-Za-z0-9._:-')"
  ssh_port="$(printf '%s' "${ssh_port_raw:-22}" | tr -cd '0-9')"
  ssh_user="$(printf '%s' "${ssh_user_raw:-root}" | tr -cd 'A-Za-z0-9._-')"
  ssh_password="${ssh_password_raw:-}"
  case "${remote_collection_mode_raw:-auto}" in
    base)
      remote_collection_mode="base"
      remote_selected_collections="crowdsecurity/linux crowdsecurity/sshd"
      ;;
    *)
      remote_collection_mode="auto"
      remote_selected_collections=""
      ;;
  esac

  [[ -n "${node_name}" ]] || fail "$(T "Имя VPS не может быть пустым." "VPS name cannot be empty.")"
  [[ -n "${vps_ip}" ]] || fail "$(T "IP VPS не может быть пустым." "VPS IP cannot be empty.")"
  [[ -n "${ssh_host}" ]] || fail "$(T "SSH host не может быть пустым." "SSH host cannot be empty.")"
  is_valid_port "${ssh_port}" || fail "$(T "SSH порт некорректен." "Invalid SSH port.")"
  [[ -n "${ssh_user}" ]] || fail "$(T "SSH логин не может быть пустым." "SSH login cannot be empty.")"
  [[ -n "${ssh_password}" ]] || fail "$(T "SSH пароль не может быть пустым." "SSH password cannot be empty.")"

  if [[ "${vps_ip}" == *:* ]]; then
    vps_cidr="${vps_ip}/128"
  else
    vps_cidr="${vps_ip}/32"
  fi

  if [[ -z "${ALLOWED_RANGES}" ]]; then
    ALLOWED_RANGES="${vps_cidr}"
  elif ! echo ",${ALLOWED_RANGES}," | grep -q ",${vps_cidr},"; then
    ALLOWED_RANGES="${ALLOWED_RANGES},${vps_cidr}"
  fi

  bouncer_key="$(openssl rand -hex 32)"

  if ! run_with_live_progress "$(T "Подготовка подключения VPS" "Preparing VPS connection")" create_vps_connection_apply_common; then
    return 1
  fi

  runner="$(mktemp)"
  build_remote_vps_installer_script "${runner}"

  if ! run_with_live_progress "$(T "Установка SSH-клиента" "Installing SSH client tools")" ensure_remote_ssh_tools; then
    rm -f "${runner}"
    return 1
  fi

  remote_install_apply() {
    echo "Проверка SSH-доступа к ${ssh_user}@${ssh_host}:${ssh_port}"
    remote_ssh_base "echo ssh-ok"
    echo "Загрузка установщика на VPS"
    remote_upload_runner "${runner}"
    echo "Запуск удалённой установки VPS"
    remote_run_runner
  }

  if ! run_with_live_progress "$(T "Удалённая установка VPS node" "Remote VPS node installation")" remote_install_apply; then
    rm -f "${runner}"
    return 1
  fi
  rm -f "${runner}"

  if run_with_live_progress "$(T "Ожидание и validate ${node_name}" "Waiting and validating ${node_name}")" wait_for_machine_and_validate "${node_name}" 300; then
    run_with_live_progress "$(T "Перезапуск CrowdSec на VPS после validate" "Restarting CrowdSec on VPS after validate")" remote_restart_vps_services_after_validate || true
  else
    warn "$(T "Machine не была подтверждена автоматически. После ручного validate перезапусти CrowdSec на VPS." "Machine was not validated automatically. After manual validate, restart CrowdSec on the VPS.")"
  fi

  tmp="$(mktemp)"
  {
    echo "$(T "Удалённая установка VPS завершена." "Remote VPS installation completed.")"
    echo
    echo "VPS name / Machine name:"
    echo "${node_name}"
    echo
    echo "Allowed VPS IP:"
    echo "${vps_ip} (${vps_cidr})"
    echo
    echo "Central LAPI URL:"
    echo "${VPS_LAPI_URL}"
    echo
    echo "Collections mode:"
    echo "${remote_collection_mode}"
    echo
    echo "Remote SSH:"
    echo "${ssh_user}@${ssh_host}:${ssh_port}"
    echo
    echo "$(T "Запись сохранена в:" "Record saved to:") ${CONNECTIONS_FILE}"
  } >"${tmp}"
  show_file "$(T "Удалённая установка VPS" "Remote VPS installation")" "${tmp}"
  rm -f "${tmp}"
}

create_named_vps_bouncer_key_manual() {
  safe_source_env
  local node_name vps_ip vps_cidr bouncer_key tmp rc
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    set +e
    node_name="$(whiptail --title " Мастер подключения VPS " --inputbox "Имя VPS.\n\nЭто же имя укажи в VPS-скрипте как Machine name. Оно будет видно в CrowdSec Manager." 13 92 "" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0
    set +e
    vps_ip="$(whiptail --title " Мастер подключения VPS " --inputbox "Внешний IP VPS, которому разрешить доступ к LAPI.\n\nСкрипт сам добавит его как /32 в LAPI и UFW. CIDR вручную вводить не нужно." 13 92 "" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0
  else
    read -rp "Имя VPS/bouncer, такое же как Machine name в VPS-скрипте: " node_name
    read -rp "Внешний IP VPS для доступа к LAPI: " vps_ip
  fi

  node_name="$(printf '%s' "${node_name:-}" | tr -cd 'A-Za-z0-9._:-')"
  [[ -n "${node_name}" ]] || fail "Имя bouncer не может быть пустым."
  vps_ip="$(printf '%s' "${vps_ip:-}" | tr -cd '0-9A-Fa-f:.')"
  [[ -n "${vps_ip}" ]] || fail "IP VPS не может быть пустым."

  if [[ "${vps_ip}" == *:* ]]; then
    vps_cidr="${vps_ip}/128"
  else
    vps_cidr="${vps_ip}/32"
  fi

  if [[ -z "${ALLOWED_RANGES}" ]]; then
    ALLOWED_RANGES="${vps_cidr}"
  elif ! echo ",${ALLOWED_RANGES}," | grep -q ",${vps_cidr},"; then
    ALLOWED_RANGES="${ALLOWED_RANGES},${vps_cidr}"
  fi

  bouncer_key="$(openssl rand -hex 32)"

  create_named_vps_bouncer_key_apply() {
    echo "Удаление старого bouncer: ${node_name}"
    if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
      docker exec crowdsec cscli bouncers delete "${node_name}" || true
      echo "Регистрация нового bouncer в Docker LAPI: ${node_name}"
      docker exec crowdsec cscli bouncers add "${node_name}" --key "${bouncer_key}"
    else
      cscli bouncers delete "${node_name}" || true
      echo "Регистрация нового bouncer в локальном LAPI: ${node_name}"
      cscli bouncers add "${node_name}" --key "${bouncer_key}"
    fi

    echo "Сохранение central.env"
    save_env

    echo "Обновление config.yaml CrowdSec LAPI"
    configure_docker_crowdsec_lapi

    echo "Перезапуск контейнера CrowdSec"
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)

    echo "Обновление правил UFW"
    configure_ufw_full

    echo "Запись подключения в ${CONNECTIONS_FILE}"
    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"
    touch "${CONNECTIONS_FILE}"
    chmod 600 "${CONNECTIONS_FILE}"
    awk -F'\t' -v name="${node_name}" '($2 != name)' "${CONNECTIONS_FILE}" >"${CONNECTIONS_FILE}.tmp" || true
    mv "${CONNECTIONS_FILE}.tmp" "${CONNECTIONS_FILE}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "${node_name}" "${vps_ip}" "${VPS_LAPI_URL}" "${AUTO_REG_TOKEN}" "${bouncer_key}" >>"${CONNECTIONS_FILE}"
  }

  if ! run_with_live_progress "Регистрация ноды VPS" create_named_vps_bouncer_key_apply; then
    return 1
  fi

  tmp="$(mktemp)"
  {
    echo "Данные для установки VPS:"
    echo
    echo "VPS name / Machine name:"
    echo "${node_name}"
    echo
    echo "Разрешённый IP VPS:"
    echo "${vps_ip} (${vps_cidr})"
    echo
    echo "Central LAPI URL:"
    echo "${VPS_LAPI_URL}"
    echo
    echo "AUTO_REG_TOKEN:"
    echo "${AUTO_REG_TOKEN}"
    echo
    echo "BOUNCER_KEY:"
    echo "${bouncer_key}"
    echo
    echo "Важно:"
    echo "- Используй этот bouncer key только на VPS '${node_name}'."
    echo "- В CrowdSec Manager bouncer будет отображаться как '${node_name}', а не shared-firewall-bouncer."
    echo "- Запись сохранена в ${CONNECTIONS_FILE}."
  } >"${tmp}"

  show_file "Индивидуальный bouncer key VPS" "${tmp}"
  rm -f "${tmp}"

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    if whiptail --title " Validate VPS machine " --yes-button "Ждать и подтвердить" --no-button "Позже" --yesno "После запуска vps.sh на VPS machine должна появиться на central LAPI.\n\nЖдать регистрацию '${node_name}' и автоматически выполнить validate?" 12 86; then
      run_with_live_progress "Ожидание и validate ${node_name}" wait_for_machine_and_validate "${node_name}" 300 || true
    fi
  else
    echo
    read -rp "Ждать регистрацию '${node_name}' и автоматически выполнить validate? [y/N]: " wait_confirm
    if [[ "${wait_confirm:-N}" =~ ^[Yy]$ ]]; then
      run_with_live_progress "Ожидание и validate ${node_name}" wait_for_machine_and_validate "${node_name}" 300 || true
      pause
    fi
  fi
}


get_crowdsec_config_dir() {
  if [[ -f "${MANAGER_COMPOSE_DIR}/crowdsec-config/config.yaml" ]]; then
    printf '%s' "${MANAGER_COMPOSE_DIR}/crowdsec-config"
  elif [[ -f "${COMPOSE_DIR}/crowdsec-config/config.yaml" ]]; then
    printf '%s' "${COMPOSE_DIR}/crowdsec-config"
  elif [[ -d /etc/crowdsec ]]; then
    printf '%s' "/etc/crowdsec"
  else
    printf '%s' "${COMPOSE_DIR}/crowdsec-config"
  fi
}

restart_crowdsec_runtime() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
    docker restart crowdsec
  elif systemctl list-unit-files crowdsec.service >/dev/null 2>&1; then
    systemctl restart crowdsec
  else
    return 0
  fi
}

install_or_update_remote_syslog_receiver() {
  local port="${1:-${DEFAULT_REMOTE_SYSLOG_PORT}}"
  local proto="${2:-udp}"
  local mode="${3:-filtered}"
  local cfg_dir acquis_file rsyslog_conf logrotate_conf any_full="no"

  [[ "${port}" =~ ^[0-9]+$ ]] || fail "$(T "Некорректный порт syslog." "Invalid syslog port.")"

  echo "Установка rsyslog и подготовка каталогов удалённых логов..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y rsyslog

  mkdir -p "${REMOTE_SYSLOG_DIR}" "${REMOTE_SYSLOG_DIAG_DIR}"
  chmod 750 "${REMOTE_SYSLOG_DIR}" "${REMOTE_SYSLOG_DIAG_DIR}"

  if [[ -s "${SYSLOG_DEVICES_FILE}" ]] && awk -F'\t' '($5=="full"){found=1} END{exit found?0:1}' "${SYSLOG_DEVICES_FILE}"; then
    any_full="yes"
  fi
  [[ "${mode}" == "full" ]] && any_full="yes"

  rsyslog_conf="/etc/rsyslog.d/30-crowdsec-remote-devices.conf"
  cat > "${rsyslog_conf}" <<EOF
# Managed by crowdsec-central-menu.
# Receives a COPY of remote syslog from routers/firewalls/bouncer-only devices.
# By default only security/firewall/auth-like messages are written to CrowdSec intake.
# Full diagnostic logging is optional and goes to ${REMOTE_SYSLOG_DIAG_DIR}, not to CrowdSec intake.
module(load="imudp")
input(type="imudp" port="${port}" ruleset="crowdsec_remote_devices")

module(load="imtcp")
input(type="imtcp" port="${port}" ruleset="crowdsec_remote_devices")

template(name="CrowdSecRemoteSecurityFile" type="string" string="${REMOTE_SYSLOG_DIR}/%fromhost-ip%.security.log")
template(name="CrowdSecRemoteDiagnosticFile" type="string" string="${REMOTE_SYSLOG_DIAG_DIR}/%fromhost-ip%.full.log")

ruleset(name="crowdsec_remote_devices") {
  # Keep only security/auth/firewall-ish events for CrowdSec:
  # dropbear/sshd/login/auth failures and firewall/kernel/nftables/iptables drops/rejects.
  if (
      re_match(\$programname, "dropbear|sshd|firewall|fw3|fw4|kernel|nft|iptables") or
      re_match(\$msg, "dropbear|sshd|auth|login|Login|failed|Failed|failure|invalid|Invalid|refused|Refused|denied|Denied|DROP|Drop|drop|REJECT|Reject|reject|blocked|Blocked|ban|Ban|nft|iptables|firewall|Firewall|kernel")
     ) then {
    action(type="omfile" dynaFile="CrowdSecRemoteSecurityFile" FileCreateMode="0640" DirCreateMode="0750")
  }
EOF
  if [[ "${any_full}" == "yes" ]]; then
    cat >> "${rsyslog_conf}" <<EOF
  # Optional full diagnostic copy. This file is NOT read by CrowdSec acquisition.
  action(type="omfile" dynaFile="CrowdSecRemoteDiagnosticFile" FileCreateMode="0640" DirCreateMode="0750")
EOF
  fi
  cat >> "${rsyslog_conf}" <<'EOF'
  stop
}
EOF

  logrotate_conf="/etc/logrotate.d/crowdsec-remote-devices"
  cat > "${logrotate_conf}" <<EOF
${REMOTE_SYSLOG_DIR}/*.log ${REMOTE_SYSLOG_DIAG_DIR}/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}
EOF

  systemctl enable --now rsyslog
  systemctl restart rsyslog

  cfg_dir="$(get_crowdsec_config_dir)"
  mkdir -p "${cfg_dir}/acquis.d"
  acquis_file="${cfg_dir}/acquis.d/remote-syslog-devices.yaml"
  cat > "${acquis_file}" <<EOF
# Managed by crowdsec-central-menu.
# Filtered security/firewall/auth logs received by host rsyslog from routers/firewalls/bouncer-only devices.
# Full diagnostic logs are intentionally not read by CrowdSec.
source: file
filename: ${REMOTE_SYSLOG_DIR}/*.security.log
labels:
  type: syslog
  service: remote-device
EOF

  echo "Acquisition создан: ${acquis_file}"
  restart_crowdsec_runtime || true
  echo "Filtered syslog intake готов на порту ${port}/udp и ${port}/tcp."
  if [[ "${any_full}" == "yes" ]]; then
    echo "Full diagnostic copy включена: ${REMOTE_SYSLOG_DIAG_DIR}/*.full.log"
  fi
}

record_remote_syslog_device() {
  local name="$1" cidr="$2" port="$3" proto="$4" mode="${5:-filtered}"
  case "${mode}" in filtered|full) ;; *) mode="filtered" ;; esac
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"
  touch "${SYSLOG_DEVICES_FILE}"
  chmod 600 "${SYSLOG_DEVICES_FILE}"
  awk -F'\t' -v name="${name}" '($1 != name)' "${SYSLOG_DEVICES_FILE}" >"${SYSLOG_DEVICES_FILE}.tmp" || true
  mv "${SYSLOG_DEVICES_FILE}.tmp" "${SYSLOG_DEVICES_FILE}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${name}" "${cidr}" "${port}" "${proto}" "${mode}" "$(date -Is)" >>"${SYSLOG_DEVICES_FILE}"
}

show_remote_syslog_devices() {
  local tmp
  tmp="$(mktemp)"
  {
    echo "$(T "Устройства, которым открыт syslog intake на central:" "Devices allowed to send syslog to central:")"
    echo
    if [[ -s "${SYSLOG_DEVICES_FILE}" ]]; then
      awk -F'\t' 'BEGIN {printf "%-28s %-24s %-8s %-8s %-10s %s\n", "NAME", "CIDR", "PORT", "PROTO", "MODE", "ADDED"} {mode=$5; added=$6; if (mode=="" || mode ~ /^20/) {added=mode; mode="filtered"}; printf "%-28s %-24s %-8s %-8s %-10s %s\n", $1, $2, $3, $4, mode, added}' "${SYSLOG_DEVICES_FILE}"
    else
      echo "$(T "Пока нет устройств syslog." "No syslog devices yet.")"
    fi
    echo
    echo "$(T "Важно: bouncer сам не отправляет события. OpenWrt/устройство отправляет копию syslog на central, локальный logread на устройстве при этом остаётся. По умолчанию central пишет в CrowdSec только отфильтрованные security/firewall/auth события, а не весь лог." "Important: a bouncer does not send events. OpenWrt/the device sends a syslog copy to central, while local logread on the device remains available. By default central writes only filtered security/firewall/auth events to CrowdSec, not the full log.")"
  } > "${tmp}"
  show_file "$(T "Syslog устройства" "Syslog devices")" "${tmp}"
  rm -f "${tmp}"
}


create_openwrt_bouncer_connection() {
  safe_source_env
  local router_name_raw router_ip_raw router_cidr lapi_url_raw rc tmp syslog_enable_raw syslog_port_raw syslog_proto_raw
  local node_name vps_ip bouncer_key

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    set +e
    router_name_raw="$(whiptail --title " $(T "Bouncer/API device" "Bouncer/API device") " --inputbox "$(T "Имя устройства / bouncer name.\n\nНапример: openwrt-router, home-router, gateway-1, edge-bouncer.\nЭто имя будет видно в CrowdSec Manager в списке bouncers." "Device name / bouncer name.\n\nExample: openwrt-router, home-router, gateway-1, edge-bouncer.\nThis name will be visible in CrowdSec Manager in the bouncers list.")" 13 92 "bouncer-device" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    set +e
    router_ip_raw="$(whiptail --title " $(T "Bouncer/API device" "Bouncer/API device") " --inputbox "$(T "IP или CIDR устройства, которому разрешить доступ к LAPI.\n\nЕсли устройство в одной LAN с central, обычно это его LAN IP как /32, например 192.168.1.1/32.\nЕсли доступ уже разрешён локальной подсетью, всё равно лучше указать конкретный IP." "Device IP or CIDR allowed to access LAPI.\n\nIf the device is in the same LAN as central, this is usually its LAN IP as /32, for example 192.168.1.1/32.\nEven if local subnet access is already allowed, a specific IP is better.")" 15 96 "" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    local default_lapi="${LOCAL_LAPI_URL}"
    if [[ -n "${PUBLIC_LAPI_URL:-}" ]]; then
      default_lapi="${VPS_LAPI_URL}"
    fi
    set +e
    lapi_url_raw="$(whiptail --title " $(T "Bouncer/API LAPI URL" "Bouncer/API LAPI URL") " --inputbox "$(T "Какой LAPI URL прописать на устройстве с bouncer/API?\n\nДля устройства в одной локальной сети обычно используй локальный URL central:\n${LOCAL_LAPI_URL}\n\nЕсли устройство ходит через Nginx Proxy Manager/TLS, используй:\n${VPS_LAPI_URL}" "Which LAPI URL should be configured on the bouncer/API device?\n\nFor a device in the same LAN, usually use the local central URL:\n${LOCAL_LAPI_URL}\n\nIf the device reaches central through Nginx Proxy Manager/TLS, use:\n${VPS_LAPI_URL}")" 17 96 "${default_lapi}" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0

    syslog_enable_raw="no"
    syslog_port_raw="${DEFAULT_REMOTE_SYSLOG_PORT}"
    syslog_proto_raw="both"

    whiptail --title " $(T "Подтверждение" "Confirmation") " --yes-button "$(T "Создать" "Create")" --no-button "$(T "Отмена" "Cancel")" --yesno "$(T "Central создаст отдельный bouncer key и добавит IP/CIDR устройства в доступ к LAPI.\n\nСобытия от роутера/устройства НЕ включаются автоматически. Если нужны события, включи их отдельно в меню: События от роутера/устройства -> Включить filtered syslog intake.\n\nПродолжить?" "Central will create a dedicated bouncer key and add the device IP/CIDR to LAPI access.\n\nEvents from the router/device are NOT enabled automatically. If events are needed, enable them separately in the menu: Router/device event intake -> Enable filtered syslog intake.\n\nContinue?")" 16 92 || return 0
  else
    read -rp "$(T "Имя устройства / bouncer name [bouncer-device]: " "Device / bouncer name [bouncer-device]: ")" router_name_raw || return 0
    router_name_raw="${router_name_raw:-bouncer-device}"
    read -rp "$(T "IP/CIDR устройства для доступа к LAPI, например 192.168.1.1/32: " "Device IP/CIDR for LAPI access, e.g. 192.168.1.1/32: ")" router_ip_raw || return 0
    local default_lapi="${LOCAL_LAPI_URL}"
    [[ -n "${PUBLIC_LAPI_URL:-}" ]] && default_lapi="${VPS_LAPI_URL}"
    read -rp "$(T "LAPI URL для устройства [${default_lapi}]: " "LAPI URL for device [${default_lapi}]: ")" lapi_url_raw || return 0
    lapi_url_raw="${lapi_url_raw:-${default_lapi}}"
    echo "$(T "События от устройства не включаются при добавлении bouncer. Их можно включить отдельно в меню событий." "Device events are not enabled while adding a bouncer. You can enable them separately in the event intake menu.")"
    syslog_enable_raw="no"
    syslog_port_raw="${DEFAULT_REMOTE_SYSLOG_PORT}"
    syslog_proto_raw="both"
  fi

  node_name="$(printf '%s' "${router_name_raw:-}" | tr -cd 'A-Za-z0-9._:-')"
  [[ -n "${node_name}" ]] || fail "$(T "Имя bouncer не может быть пустым." "Bouncer name cannot be empty.")"

  router_ip_raw="$(printf '%s' "${router_ip_raw:-}" | tr -cd '0-9A-Fa-f:.\/')"
  [[ -n "${router_ip_raw}" ]] || fail "$(T "IP/CIDR устройства не может быть пустым." "Device IP/CIDR cannot be empty.")"
  if [[ "${router_ip_raw}" == */* ]]; then
    router_cidr="${router_ip_raw}"
    vps_ip="${router_ip_raw%%/*}"
  elif [[ "${router_ip_raw}" == *:* ]]; then
    router_cidr="${router_ip_raw}/128"
    vps_ip="${router_ip_raw}"
  else
    router_cidr="${router_ip_raw}/32"
    vps_ip="${router_ip_raw}"
  fi

  lapi_url_raw="${lapi_url_raw%/}"
  [[ "${lapi_url_raw}" =~ ^https?://[^[:space:]]+$ ]] || fail "$(T "LAPI URL должен начинаться с http:// или https://" "LAPI URL must start with http:// or https://")"

  case "${syslog_enable_raw:-no}" in
    yes|y|Y|YES|Yes|да|Да) syslog_enable_raw="yes" ;;
    *) syslog_enable_raw="no" ;;
  esac
  syslog_port_raw="$(printf '%s' "${syslog_port_raw:-${DEFAULT_REMOTE_SYSLOG_PORT}}" | tr -cd '0-9')"
  syslog_port_raw="${syslog_port_raw:-${DEFAULT_REMOTE_SYSLOG_PORT}}"
  is_valid_port "${syslog_port_raw}" || fail "$(T "Некорректный syslog port." "Invalid syslog port.")"
  case "${syslog_proto_raw:-both}" in udp|tcp|both) ;; *) syslog_proto_raw="both" ;; esac

  if [[ -z "${ALLOWED_RANGES}" ]]; then
    ALLOWED_RANGES="${router_cidr}"
  elif ! echo ",${ALLOWED_RANGES}," | grep -q ",${router_cidr},"; then
    ALLOWED_RANGES="${ALLOWED_RANGES},${router_cidr}"
  fi

  bouncer_key="$(openssl rand -hex 32)"

  create_openwrt_bouncer_apply() {
    echo "Удаление старого bouncer: ${node_name}"
    if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
      docker exec crowdsec cscli bouncers delete "${node_name}" || true
      echo "Регистрация bouncer device в Docker LAPI: ${node_name}"
      docker exec crowdsec cscli bouncers add "${node_name}" --key "${bouncer_key}"
    else
      cscli bouncers delete "${node_name}" || true
      echo "Регистрация bouncer device в локальном LAPI: ${node_name}"
      cscli bouncers add "${node_name}" --key "${bouncer_key}"
    fi

    echo "Сохранение central.env"
    save_env

    echo "Обновление config.yaml CrowdSec LAPI"
    configure_docker_crowdsec_lapi

    if [[ "${syslog_enable_raw:-no}" == "yes" ]]; then
      echo "Настройка syslog intake для устройства ${node_name}"
      install_or_update_remote_syslog_receiver "${syslog_port_raw}" "${syslog_proto_raw}"
      record_remote_syslog_device "${node_name}" "${router_cidr}" "${syslog_port_raw}" "${syslog_proto_raw}"
    fi

    echo "Перезапуск контейнера CrowdSec"
    if [[ -d "${MANAGER_COMPOSE_DIR}" && -f "${MANAGER_COMPOSE_FILE}" ]]; then
      (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)
    else
      systemctl restart crowdsec || true
    fi

    echo "Обновление правил UFW"
    configure_ufw_full

    echo "Запись подключения в ${CONNECTIONS_FILE}"
    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"
    touch "${CONNECTIONS_FILE}"
    chmod 600 "${CONNECTIONS_FILE}"
    awk -F'\t' -v name="${node_name}" '($2 != name)' "${CONNECTIONS_FILE}" >"${CONNECTIONS_FILE}.tmp" || true
    mv "${CONNECTIONS_FILE}.tmp" "${CONNECTIONS_FILE}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "${node_name}" "${vps_ip}" "${lapi_url_raw}" "BOUNCER_ONLY_DEVICE" "${bouncer_key}" >>"${CONNECTIONS_FILE}"
  }

  if ! run_with_live_progress "$(T "Регистрация bouncer/API device" "Registering bouncer/API device")" create_openwrt_bouncer_apply; then
    return 1
  fi

  tmp="$(mktemp)"
  {
    echo "$(T "Данные для подключения устройства с bouncer/API:" "Bouncer/API device connection data:")"
    echo
    echo "Bouncer name:"
    echo "${node_name}"
    echo
    echo "Allowed device IP/CIDR:"
    echo "${router_cidr}"
    echo
    echo "API URL / LAPI URL:"
    echo "${lapi_url_raw}"
    echo
    echo "API key / BOUNCER_KEY:"
    echo "${bouncer_key}"
    echo
    if [[ "${syslog_enable_raw:-no}" == "yes" ]]; then
      echo "$(T "Syslog intake на central:" "Syslog intake on central:")"
      echo "central_syslog_host=${LAN_IP}"
      echo "central_syslog_port=${syslog_port_raw}"
      echo "central_syslog_protocol=${syslog_proto_raw}"
      echo "central_filtered_log_files=${REMOTE_SYSLOG_DIR}/*.security.log"
      echo
      echo "$(T "Важно: именно syslog нужен для появления событий/метрик устройства в CrowdSec Manager. Один bouncer показывает только Connected/Last Pull и не отправляет логи." "Important: syslog is required for the device events/metrics to appear in CrowdSec Manager. A bouncer alone only shows Connected/Last Pull and does not send logs.")"
      echo
      echo "OpenWrt syslog UCI example:"
      echo "uci set system.@system[0].log_ip='${LAN_IP}'"
      echo "uci set system.@system[0].log_port='${syslog_port_raw}'"
      echo "uci set system.@system[0].log_proto='udp'"
      echo "uci commit system"
      echo "/etc/init.d/log restart"
      echo
      echo "$(T "Проверка поступления логов на central:" "Check log flow on central:")"
      echo "sudo tail -f ${REMOTE_SYSLOG_DIR}/${vps_ip}.security.log"
      echo "sudo docker exec crowdsec cscli metrics"
      echo
    else
      echo "$(T "Syslog intake не включён. В CrowdSec Manager это устройство будет видно только как bouncer Connected/Last Pull, без событий и метрик логов." "Syslog intake is not enabled. In CrowdSec Manager this device will only appear as a bouncer Connected/Last Pull, without log events and metrics.")"
      echo
    fi
    echo "LuCI:"
    echo "Services -> CrowdSec Firewall Bouncer"
    echo "Enabled: on"
    echo "API URL: ${lapi_url_raw}/"
    echo "API key: ${bouncer_key}"
    echo
    echo "Generic bouncer/API settings:"
    echo "api_url=${lapi_url_raw}/"
    echo "api_key=${bouncer_key}"
    echo
    echo "OpenWrt UCI examples:"
    echo
    echo "UCI variant 1 (/etc/config/crowdsec):"
    echo "uci set crowdsec.@bouncer[0].enabled='1'"
    echo "uci set crowdsec.@bouncer[0].api_url='${lapi_url_raw}/'"
    echo "uci set crowdsec.@bouncer[0].api_key='${bouncer_key}'"
    echo "uci commit crowdsec"
    echo "/etc/init.d/crowdsec-firewall-bouncer restart"
    echo "/etc/init.d/crowdsec-firewall-bouncer status"
    echo
    echo "UCI variant 2 (/etc/config/crowdsec-firewall-bouncer):"
    echo "uci set crowdsec-firewall-bouncer.@bouncer[0].enabled='1'"
    echo "uci set crowdsec-firewall-bouncer.@bouncer[0].api_url='${lapi_url_raw}/'"
    echo "uci set crowdsec-firewall-bouncer.@bouncer[0].api_key='${bouncer_key}'"
    echo "uci commit crowdsec-firewall-bouncer"
    echo "/etc/init.d/crowdsec-firewall-bouncer restart"
    echo "/etc/init.d/crowdsec-firewall-bouncer status"
    echo
    echo "$(T "Проверка на central:" "Check on central:")"
    echo "sudo docker exec crowdsec cscli bouncers list"
    echo
    echo "$(T "Важно: устройство, на котором установлен только bouncer/API без CrowdSec agent, не является machine и не требует validate. Это только bouncer, который забирает decisions с central LAPI и применяет их на своей стороне." "Important: a device with only bouncer/API and without CrowdSec agent is not a machine and does not need validate. It is only a bouncer that pulls decisions from central LAPI and applies them on its side.")"
    echo "$(T "Запись сохранена в:" "Record saved to:") ${CONNECTIONS_FILE}"
  } >"${tmp}"

  show_file "$(T "Bouncer/API device" "Bouncer/API device")" "${tmp}"
  rm -f "${tmp}"
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
  AUTO_REG_TOKEN="${AUTO_REG_TOKEN}" ALLOWED_RANGES="${ALLOWED_RANGES}" LOCAL_LAPI_ALLOWED_RANGES="${LOCAL_LAPI_ALLOWED_RANGES}" python3 - "${config_file}" <<'PY'
import os, re, sys, yaml
path = sys.argv[1]
with open(path, "r", errors="replace") as f:
    cfg = yaml.safe_load(f) or {}
cfg.setdefault("api", {})
cfg["api"].setdefault("server", {})
cfg["api"]["server"]["listen_uri"] = "0.0.0.0:8080"
ranges = []
for env_name in ("LOCAL_LAPI_ALLOWED_RANGES", "ALLOWED_RANGES"):
    for item in os.environ.get(env_name, "").split(","):
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
  if [[ "${WEB_PORT}" == "${LAPI_PORT}" ]]; then
    fail "Ошибка конфигурации: WEB_PORT и LAPI_PORT не могут быть одинаковыми (${WEB_PORT}). Измени порты через меню."
  fi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    local fifo
    fifo=$(mktemp -u)
    mkfifo "${fifo}"

    whiptail --title " Развертывание CrowdSec " --gauge "Подготовка окружения и бэкап..." 8 78 0 < "${fifo}" &
    local gauge_pid=$!
    exec 3> "${fifo}"

    echo -e "XXX\n10\nОчистка старых контейнеров Web UI...\nXXX" >&3
    remove_all_web_ui_containers >/dev/null 2>&1

    echo -e "XXX\n20\nРезервное копирование и удаление apt-версии CrowdSec...\nXXX" >&3
    backup_and_remove_apt_crowdsec >/dev/null 2>&1

    echo -e "XXX\n35\nИнициализация директорий Docker-окружения...\nXXX" >&3
    mkdir -p "${COMPOSE_DIR}"
    chmod 755 "${COMPOSE_DIR}"
    mkdir -p "${COMPOSE_DIR}/crowdsec-db" "${COMPOSE_DIR}/crowdsec-config"
    chmod 700 "${COMPOSE_DIR}/crowdsec-db" "${COMPOSE_DIR}/crowdsec-config"
    sleep 0.1

    echo -e "XXX\n45\nГенерация манифеста docker-compose.yml...\nXXX" >&3
    cat >"${COMPOSE_FILE}" <<EOF
services:
  crowdsec:
    image: crowdsecurity/crowdsec:v1.6.2
    container_name: crowdsec
    restart: unless-stopped
    environment:
      - COLLECTIONS=crowdsecurity/linux crowdsecurity/sshd
      - GID=1000
    ports:
      - "${LAPI_PORT}:8080"
    volumes:
      - "${COMPOSE_DIR}/crowdsec-db:/var/lib/crowdsec/data"
      - "${COMPOSE_DIR}/crowdsec-config:/etc/crowdsec"
      - /var/log:/var/log:ro
    networks:
      - crowdsec_net

  crowdsec-manager:
    image: ${MANAGER_IMAGE}
    container_name: crowdsec-manager
    restart: unless-stopped
    ports:
      - "${LAN_IP}:${WEB_PORT}:8080"
    environment:
      - PORT=8080
      - ENVIRONMENT=production
      - DATABASE_PATH=/app/data/settings.db
      - CONFIG_DIR=/app/config
      - BACKUP_DIR=/app/backups
      - INCLUDE_CROWDSEC=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - crowdsec-manager-data:/app/data
      - crowdsec-manager-config:/app/config
      - crowdsec-manager-backups:/app/backups
    networks:
      - crowdsec_net
    depends_on:
      - crowdsec

volumes:
  crowdsec-manager-data:
  crowdsec-manager-config:
  crowdsec-manager-backups:

networks:
  crowdsec_net:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.16.238.0/24
EOF

    echo -e "XXX\n55\nЗагрузка Docker-образов (Pulling images). Может занять время...\nXXX" >&3
    (cd "${COMPOSE_DIR}" && docker compose pull) >/dev/null 2>&1

    echo -e "XXX\n70\nСборка и холодный запуск контейнеров CrowdSec...\nXXX" >&3
    (cd "${COMPOSE_DIR}" && docker compose up -d --remove-orphans) >/dev/null 2>&1
    
    echo -e "XXX\n80\nОжидание инициализации структуры (8 сек)...\nXXX" >&3
    sleep 8

    echo -e "XXX\n85\nИнъекция параметров ALLOWED_RANGES в LAPI-конфиг...\nXXX" >&3
    configure_docker_crowdsec_lapi >/dev/null 2>&1
    (cd "${COMPOSE_DIR}" && docker compose restart crowdsec) >/dev/null 2>&1
    
    echo -e "XXX\n90\nОжидание перезапуска контейнера (5 сек)...\nXXX" >&3
    sleep 5

    echo -e "XXX\n95\nРегистрация системного bouncer-интерфейса (Shared Key)...\nXXX" >&3
    docker exec crowdsec cscli bouncers delete shared-firewall-bouncer >/dev/null 2>&1 || true
    docker exec crowdsec cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null || true

    WEB_UI_TYPE="manager"
    save_env >/dev/null 2>&1

    echo -e "XXX\n100\nУстановка стека успешно завершена!\nXXX" >&3
    sleep 0.2

    exec 3>&-
    wait "${gauge_pid}" 2>/dev/null || true
    rm -f "${fifo}"

    whiptail --title " Успех " --msgbox "Развёрнут CrowdSec Manager в Docker.\n\nWeb UI: http://${LAN_IP}:${WEB_PORT}\nLocal LAPI port: ${LAPI_PORT}" 11 78
  else
    log "Устанавливаю CrowdSec Manager + Dockerized CrowdSec..."
    remove_all_web_ui_containers
    backup_and_remove_apt_crowdsec

    mkdir -p "${COMPOSE_DIR}"
    chmod 755 "${COMPOSE_DIR}"
    mkdir -p "${COMPOSE_DIR}/crowdsec-db" "${COMPOSE_DIR}/crowdsec-config"
    chmod 700 "${COMPOSE_DIR}/crowdsec-db" "${COMPOSE_DIR}/crowdsec-config"

    cat >"${COMPOSE_FILE}" <<EOF
services:
  crowdsec:
    image: crowdsecurity/crowdsec:v1.6.2
    container_name: crowdsec
    restart: unless-stopped
    environment:
      - COLLECTIONS=crowdsecurity/linux crowdsecurity/sshd
      - GID=1000
    ports:
      - "${LAPI_PORT}:8080"
    volumes:
      - "${COMPOSE_DIR}/crowdsec-db:/var/lib/crowdsec/data"
      - "${COMPOSE_DIR}/crowdsec-config:/etc/crowdsec"
      - /var/log:/var/log:ro
    networks:
      - crowdsec_net

  crowdsec-manager:
    image: ${MANAGER_IMAGE}
    container_name: crowdsec-manager
    restart: unless-stopped
    ports:
      - "${LAN_IP}:${WEB_PORT}:8080"
    environment:
      - PORT=8080
      - ENVIRONMENT=production
      - DATABASE_PATH=/app/data/settings.db
      - CONFIG_DIR=/app/config
      - BACKUP_DIR=/app/backups
      - INCLUDE_CROWDSEC=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - crowdsec-manager-data:/app/data
      - crowdsec-manager-config:/app/config
      - crowdsec-manager-backups:/app/backups
    networks:
      - crowdsec_net
    depends_on:
      - crowdsec

volumes:
  crowdsec-manager-data:
  crowdsec-manager-config:
  crowdsec-manager-backups:

networks:
  crowdsec_net:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.16.238.0/24
EOF

    (cd "${COMPOSE_DIR}" && docker compose pull)
    (cd "${COMPOSE_DIR}" && docker compose up -d --remove-orphans)
    log "Ожидаю 8 секунд для инициализации структуры каталогов в контейнере..."
    sleep 8

    configure_docker_crowdsec_lapi
    (cd "${COMPOSE_DIR}" && docker compose restart crowdsec)
    log "Ожидаю 5 секунд для перезапуска crowdsec..."
    sleep 5

    docker exec crowdsec cscli bouncers delete shared-firewall-bouncer >/dev/null 2>&1 || true
    docker exec crowdsec cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null

    WEB_UI_TYPE="manager"
    save_env
    ok "Развёрнут CrowdSec Manager в Docker. Web UI: http://${LAN_IP}:${WEB_PORT}, local LAPI port: ${LAPI_PORT}"
  fi
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

configure_ufw_full_apply() {
  safe_source_env
  if ! command -v ufw >/dev/null 2>&1; then
    echo "ufw не найден, пропускаю настройку firewall."
    return 0
  fi

  local backup_dir ssh_port client_ip old_ifs r
  backup_dir="$(backup_ufw_state)"
  echo "Backup текущего UFW сохранён: ${backup_dir}"

  echo "Сброс текущей конфигурации UFW..."
  ufw --force reset

  echo "Установка базовых политик UFW..."
  ufw default deny incoming
  ufw default allow outgoing

  echo "Сохранение SSH-доступа..."
  client_ip="${SSH_CONNECTION%% *}"
  while IFS= read -r ssh_port; do
    [[ -n "${ssh_port}" ]] || continue
    ufw allow "${ssh_port}/tcp" comment "keep SSH port ${ssh_port}" || true
    if [[ -n "${client_ip}" && "${client_ip}" != "${SSH_CONNECTION}" ]]; then
      ufw allow from "${client_ip}" to any port "${ssh_port}" proto tcp comment "keep current SSH client" || true
    fi
  done < <(get_sshd_ports)

  echo "Открытие Web UI только для приватных диапазонов..."
  ufw allow from 10.0.0.0/8 to any port "${WEB_PORT}" proto tcp
  ufw allow from 172.16.0.0/12 to any port "${WEB_PORT}" proto tcp
  ufw allow from 192.168.0.0/16 to any port "${WEB_PORT}" proto tcp

  echo "Открытие LAPI для Docker, Nginx Proxy Manager и разрешённых VPS/IP..."
  ufw allow from 172.16.0.0/12 to any port "${LAPI_PORT}" proto tcp
  ufw allow from 172.17.0.0/12 to any port "${LAPI_PORT}" proto tcp
  ufw allow from 172.16.238.0/24 to any port "${LAPI_PORT}" proto tcp
  if [[ -n "${NPM_ALLOWED_CIDR:-}" ]]; then
    echo "Разрешаю доступ Nginx Proxy Manager к LAPI: ${NPM_ALLOWED_CIDR}"
    ufw allow from "${NPM_ALLOWED_CIDR}" to any port "${LAPI_PORT}" proto tcp
  fi

  old_ifs="${IFS}"
  IFS=','
  for r in ${ALLOWED_RANGES}; do
    IFS="${old_ifs}"
    r="$(echo "${r}" | xargs)"
    [[ -n "${r}" ]] || continue
    echo "Разрешаю доступ к LAPI для ${r}..."
    ufw allow from "${r}" to any port "${LAPI_PORT}" proto tcp
  done
  IFS="${old_ifs}"

  if [[ -s "${SYSLOG_DEVICES_FILE}" ]]; then
    echo "Открытие syslog intake для устройств с bouncer/API..."
    while IFS=$'\t' read -r syslog_name syslog_cidr syslog_port syslog_proto syslog_mode _; do
      [[ -n "${syslog_cidr:-}" && -n "${syslog_port:-}" ]] || continue
      case "${syslog_proto:-both}" in
        udp)
          ufw allow from "${syslog_cidr}" to any port "${syslog_port}" proto udp comment "crowdsec syslog ${syslog_name}" || true
          ;;
        tcp)
          ufw allow from "${syslog_cidr}" to any port "${syslog_port}" proto tcp comment "crowdsec syslog ${syslog_name}" || true
          ;;
        *)
          ufw allow from "${syslog_cidr}" to any port "${syslog_port}" proto udp comment "crowdsec syslog ${syslog_name}" || true
          ufw allow from "${syslog_cidr}" to any port "${syslog_port}" proto tcp comment "crowdsec syslog ${syslog_name}" || true
          ;;
      esac
    done < "${SYSLOG_DEVICES_FILE}"
  fi

  echo "Включение UFW..."
  ufw --force enable
  ufw status verbose || true
  ok "UFW настроен и включен. Backup: ${backup_dir}"
}

configure_ufw_full() {
  safe_source_env
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    if ! confirm_dangerous_action "Настройка UFW" "Скрипт сделает backup текущих правил, затем выполнит ufw --force reset и пересоздаст правила для SSH, Web UI и LAPI. Если SSH использует нестандартную схему доступа, проверь правила после выполнения."; then
      warn "Настройка UFW отменена пользователем."
      return 1
    fi
  fi

  run_with_live_progress "Настройка UFW firewall" configure_ufw_full_apply
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
  local tmp diff_file
  tmp="$(mktemp)"
  diff_file="$(mktemp)"
  curl -fsSL -H "Cache-Control: no-cache" "${SCRIPT_RAW_URL}?$(date +%s)" -o "${tmp}"
  bash -n "${tmp}"

  if [[ -f "${INSTALLED_SCRIPT}" ]]; then
    diff -u "${INSTALLED_SCRIPT}" "${tmp}" >"${diff_file}" 2>/dev/null || true
  else
    echo "${INSTALLED_SCRIPT} отсутствует, будет установлен новый файл." >"${diff_file}"
  fi

  if [[ "${CROWDSEC_ASSUME_YES:-0}" != "1" ]]; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" ]] && tui_available; then
      whiptail --title " Diff обновления меню " --textbox "${diff_file}" 30 120 || true
    elif has_tty; then
      ${PAGER:-less} "${diff_file}" </dev/tty >/dev/tty 2>&1 || cat "${diff_file}"
    fi
    if ! confirm_dangerous_action "Обновление меню из GitHub" "Скачанный файл прошёл bash -n. Установить его в ${INSTALLED_SCRIPT}? Без SHA256/подписи это всё равно доверие к содержимому GitHub raw."; then
      rm -f "${tmp}" "${diff_file}"
      warn "Обновление меню отменено."
      return 1
    fi
  fi

  install -m 0755 "${tmp}" "${INSTALLED_SCRIPT}"
  rm -f "${tmp}" "${diff_file}"
  ok "Меню обновлено: ${INSTALLED_SCRIPT}"
}
run_install_step() {
  local title="$1"
  shift
  if run_with_live_progress "${title}" "$@"; then
    return 0
  fi
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
  if [[ -n "${PUBLIC_LAPI_URL:-}" ]]; then
    echo "Публичный LAPI через Nginx Proxy Manager: ${PUBLIC_LAPI_URL}"
    echo "В NPM Proxy Host укажи: http://${LAN_IP}:${LAPI_PORT}"
    echo "Наружу не открывай LAPI ${LAPI_PORT}, если VPS ходят через NPM."
  else
    echo "Проброс на роутере, если LAPI должен быть доступен VPS: WAN TCP ${LAPI_PORT} -> ${LAN_IP}:${LAPI_PORT}"
  fi
  echo "Не пробрасывать наружу: WAN TCP ${WEB_PORT}"
  echo "============================================================"
}

show_install_result_tui() {
  {
    show_install_result
  } | show_output "$(T "Установка завершена" "Installation complete")"
}

full_install() {
  require_root
  detect_debian
  require_interactive_install
  if bootstrap_installer_tui; then
    export CROWDSEC_TUI_MODE="installer"
    tui_theme
    whiptail --title "$(T " CrowdSec Central " " CrowdSec Central ")" --msgbox "$(T "Установка CrowdSec Central LAPI + Web UI.\n\nВсе параметры можно будет изменить позже через меню.\n\nПосле установки будет применена базовая бесплатная защита: linux + sshd collections. Платные blocklists не включаются." "Installing CrowdSec Central LAPI + Web UI.\n\nAll settings can be changed later from the menu.\n\nAfter installation, base free protection will be applied: linux + sshd collections. Paid blocklists are not enabled.")" 15 86
    if tui_yesno "$(T "Обновление системы" "System update")" "$(T "Перед установкой обновить системные пакеты Debian?" "Update Debian system packages before installation?")"; then
      do_upgrade="Y"
    else
      do_upgrade="N"
    fi
    ask_initial_settings_tui
    run_install_step "$(T "Устанавливаю базовые пакеты" "Installing base packages")" install_base
    if [[ ! "${do_upgrade:-Y}" =~ ^[Nn]$ ]]; then
      run_install_step "$(T "Обновляю системные пакеты Debian" "Updating Debian system packages")" upgrade_system_packages
    fi
    run_install_step "$(T "Устанавливаю или обновляю Docker" "Installing or updating Docker")" install_or_update_docker
    WEB_UI_TYPE="manager"
    run_install_step "$(T "Устанавливаю CrowdSec Manager + Dockerized CrowdSec" "Installing CrowdSec Manager + Dockerized CrowdSec")" install_or_update_crowdsec_manager
    run_install_step "$(T "Настраиваю базовую защиту CrowdSec" "Configuring base CrowdSec protection")" apply_initial_protection_baseline
    run_install_step "$(T "Настраиваю UFW firewall" "Configuring UFW firewall")" configure_ufw_full
    run_install_step "$(T "Устанавливаю команду меню" "Installing menu command")" install_menu_files
    show_install_result_tui
    return
  fi

  print_header
  echo "$(T "Установка CrowdSec Central LAPI + Web UI + меню управления." "Installing CrowdSec Central LAPI + Web UI + management menu.")"
  echo "$(T "Необязательные параметры можно пропустить и изменить позже." "Optional parameters can be skipped and changed later.")"
  echo
  prompt_default do_upgrade "$(T "Перед установкой обновить системные пакеты Debian? [Y/n]: " "Update Debian system packages before installation? [Y/n]: ")" "Y"
  ask_initial_settings
  install_base
  if [[ ! "${do_upgrade:-Y}" =~ ^[Nn]$ ]]; then
    upgrade_system_packages
  fi
  install_or_update_docker
  WEB_UI_TYPE="manager"
  install_or_update_crowdsec_manager
  apply_initial_protection_baseline
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
      echo "  CrowdSec Manager: режим не настроен, запусти повторную установку/переустановку."
    fi
    command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker && echo "  Docker: работает" || echo "  Docker: не работает или не установлен"
    if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]]; then
      docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^crowdsec-manager$' && echo "  Веб-морда: CrowdSec Manager работает" || echo "  Веб-морда: CrowdSec Manager не работает"
    else
      echo "  Веб-морда: CrowdSec Manager не настроен"
    fi
    echo
    echo "Порты:"
    ss -lntp 2>/dev/null | grep -E ":(${WEB_PORT}|${LAPI_PORT})" || echo "  порты ${WEB_PORT}/${LAPI_PORT} не найдены в listen"
  } >"${tmp}"
  show_file "Статус" "${tmp}"
  rm -f "${tmp}"
}

show_connection_info() {
  safe_source_env

  # Проверка наличия и непустоты файла базы данных подключений
  if [[ ! -f "${CONNECTIONS_FILE}" || ! -s "${CONNECTIONS_FILE}" ]]; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
      whiptail --title " Подключения VPS " --msgbox "Пока нет сохранённых подключений.\n\nСоздай подключение через:\nПодключения VPS и LAPI -> Создать подключение VPS/устройства/устройства" 12 78
    else
      print_header
      echo "Пока нет сохранённых подключений."
      echo
      echo "Создай подключение через:"
      echo "  Подключения VPS и LAPI -> Создать подключение VPS/устройства"
      echo
      echo "Мастер спросит имя VPS и его внешний IP, сам добавит доступ к LAPI и создаст bouncer key."
      pause
    fi
    return
  fi

  # Чтение строк из файла TSV в индексированный массив
  local lines=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && lines+=("${line}")
  done < "${CONNECTIONS_FILE}"

  local choice_num
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    local menu_args=()
    for i in "${!lines[@]}"; do
      # Извлечение полей Name (2) и IP (3) для формирования списка выбора
      local name ip
      name=$(echo "${lines[$i]}" | cut -f2)
      ip=$(echo "${lines[$i]}" | cut -f3)
      menu_args+=("$((i+1))" "${name} [${ip}]")
    done

    # Инициализация интерактивного меню выбора ноды
    choice_num=$(whiptail --title " Список подключений VPS " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --menu "Выберите ноду для просмотра полных данных подключения:" 18 78 8 "${menu_args[@]}" 3>&1 1>&2 2>&3) || true
    if [[ -z "${choice_num}" ]]; then
      return
    fi
  else
    print_header
    echo "Список подключений VPS:"
    for i in "${!lines[@]}"; do
      local name ip
      name=$(echo "${lines[$i]}" | cut -f2)
      ip=$(echo "${lines[$i]}" | cut -f3)
      echo "$((i+1)) - ${name} [${ip}]"
    done
    echo
    read -rp "Введи номер VPS для просмотра параметров (или Enter для отмены): " choice_num
    [[ -n "${choice_num}" ]] || return 0
    [[ "${choice_num}" =~ ^[0-9]+$ ]] || { warn "Нужно ввести номер."; pause; return; }
    if (( choice_num < 1 || choice_num > ${#lines[@]} )); then
      warn "Номер вне диапазона."
      pause
      return
    fi
  fi

  # Парсинг выбранной записи по TSV-структуре: Created(1), Name(2), IP(3), LAPI(4), Token(5), Key(6)
  local target_line="${lines[$((choice_num - 1))]}"
  local created name ip lapi token key
  created=$(echo "${target_line}" | cut -f1)
  name=$(echo "${target_line}" | cut -f2)
  ip=$(echo "${target_line}" | cut -f3)
  lapi=$(echo "${target_line}" | cut -f4)
  token=$(echo "${target_line}" | cut -f5)
  key=$(echo "${target_line}" | cut -f6)

  # Генерация временного конфигурационного дампа для выбранной ноды
  local tmp
  tmp="$(mktemp)"
  {
    echo "Параметры подключения для ноды: ${name}"
    echo "=================================================="
    echo "Дата создания: ${created}"
    echo "IP-адрес VPS:  ${ip}"
    echo
    if [[ "${token}" == "BOUNCER_ONLY_OPENWRT" ]]; then
      echo "Тип подключения: bouncer/API device only"
      echo "--------------------------------------------------"
      echo "API URL=${lapi}/"
      echo "API KEY=${key}"
      echo "BOUNCER_NAME=${name}"
      echo "--------------------------------------------------"
      echo
      echo "LuCI:"
      echo "Services -> CrowdSec Firewall Bouncer"
      echo "Enabled: on"
      echo "API URL: ${lapi}/"
      echo "API key: ${key}"
      echo
      echo "UCI variant 1:"
      echo "uci set crowdsec.@bouncer[0].enabled='1'"
      echo "uci set crowdsec.@bouncer[0].api_url='${lapi}/'"
      echo "uci set crowdsec.@bouncer[0].api_key='${key}'"
      echo "uci commit crowdsec"
      echo "/etc/init.d/crowdsec-firewall-bouncer restart"
      echo
      echo "UCI variant 2:"
      echo "uci set crowdsec-firewall-bouncer.@bouncer[0].enabled='1'"
      echo "uci set crowdsec-firewall-bouncer.@bouncer[0].api_url='${lapi}/'"
      echo "uci set crowdsec-firewall-bouncer.@bouncer[0].api_key='${key}'"
      echo "uci commit crowdsec-firewall-bouncer"
      echo "/etc/init.d/crowdsec-firewall-bouncer restart"
    else
      echo "Данные для копирования в VPS-скрипт:"
      echo "--------------------------------------------------"
      echo "CENTRAL_LAPI_URL=${lapi}"
      echo "AUTO_REG_TOKEN=${token}"
      echo "BOUNCER_KEY=${key}"
      echo "MACHINE_NAME=${name}"
      echo "--------------------------------------------------"
    fi
    echo
    echo "Веб-морда доступна только из локальной сети: ${LOCAL_WEB_UI}"
  } >"${tmp}"

  # Вывод сформированных данных через встроенный обработчик просмотра файлов
  show_file "Настройки VPS: ${name}" "${tmp}"
  rm -f "${tmp}"
}

show_tokens_file() {
  if [[ "${CROWDSEC_ASSUME_YES:-0}" != "1" ]]; then
    if ! confirm_dangerous_action "Показ central.env" "Файл central.env содержит токены, пароли и bouncer keys. Не показывай его при записи экрана, демонстрации терминала или постороннем доступе к консоли."; then
      return 0
    fi
  fi
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
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    new_range=$(whiptail --title " Добавление IP/CIDR " --inputbox "Введите IP/CIDR для добавления к LAPI (например, 11.22.33.44/32):" 10 78 3>&1 1>&2 2>&3) || true
    [[ -n "${new_range}" ]] || return 0
  else
    print_header
    echo "Добавление IP/CIDR для доступа к LAPI. Пример: 11.22.33.44/32"
    read -rp "Введи IP/CIDR (или Enter для отмены): " new_range
    [[ -n "${new_range}" ]] || { echo "Отменено."; pause; return; }
  fi

  new_range="$(printf '%s' "${new_range}" | tr -cd '0-9A-Za-z.:/_-')"
  if [[ -z "${new_range}" ]]; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
      whiptail --title " Ошибка " --msgbox "IP/CIDR не может быть пустым." 8 78
    else
      warn "Пусто. Ничего не добавлено."
      pause
    fi
    return
  fi

  if [[ ! "${new_range}" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]]; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
      whiptail --title " Предупреждение " --yes-button "Добавить" --no-button "$(T "Отмена" "Cancel")" --yesno "Похоже, это не CIDR.\nВсё равно добавить?" 10 78 || true
      [[ $? -eq 0 ]] || return 0
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
      if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
        whiptail --title " Ошибка " --msgbox "Этот IP/CIDR уже есть в списке." 8 78
      else
        warn "Этот IP/CIDR уже есть."
        pause
      fi
      return
    fi
    ALLOWED_RANGES="${ALLOWED_RANGES},${new_range}"
  fi

  add_allowed_range_apply() {
    echo "Запись переменных в central.env"
    save_env
    echo "Генерация конфигурации CrowdSec LAPI"
    configure_docker_crowdsec_lapi
    echo "Обновление правил UFW"
    configure_ufw_full
    echo "Перезапуск контейнера CrowdSec"
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)
  }

  if ! run_with_live_progress "Добавление IP/CIDR ${new_range}" add_allowed_range_apply; then
    return 1
  fi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Успех " --msgbox "IP/CIDR добавлен: ${new_range}" 8 78
  else
    ok "IP/CIDR добавлен: ${new_range}"
    pause
  fi
}


remove_allowed_range() {
  safe_source_env
  if [[ -z "${ALLOWED_RANGES}" ]]; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
      whiptail --title " Удаление IP/CIDR " --msgbox "Список Allowed IP/CIDR пуст." 8 78
    else
      echo "Список Allowed IP/CIDR пуст."
      pause
    fi
    return
  fi

  local remove_num
  IFS=',' read -r -ra items <<< "${ALLOWED_RANGES}"

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    local menu_args=()
    for i in "${!items[@]}"; do
      menu_args+=("$((i+1))" "${items[$i]}")
    done
    remove_num=$(whiptail --title " Удаление IP/CIDR " --cancel-button "$(T "Отмена" "Cancel")" --ok-button "Удалить" --menu "Выбери IP/CIDR для удаления:" 18 78 8 "${menu_args[@]}" 3>&1 1>&2 2>&3) || true
    [[ -n "${remove_num}" ]] || return 0
  else
    print_header
    echo "Список Allowed IP/CIDR:"
    for i in "${!items[@]}"; do
      echo "$((i+1)) - ${items[$i]}"
    done
    echo
    read -rp "Введи номер для удаления (или Enter для отмены): " remove_num
    [[ -n "${remove_num}" ]] || { echo "Отменено."; pause; return; }
    [[ "${remove_num}" =~ ^[0-9]+$ ]] || { warn "Нужно ввести номер."; pause; return; }
    if (( remove_num < 1 || remove_num > ${#items[@]} )); then
      warn "Номер вне диапазона."
      pause
      return
    fi
  fi

  local target_idx=$((remove_num - 1))
  local removed_cidr="${items[target_idx]}"
  local removed_ip="${removed_cidr%%/*}"
  local machine_name=""
  local bouncer_name=""
  if [[ -f "${CONNECTIONS_FILE}" && -n "${removed_ip}" ]]; then
    machine_name=$(grep "${removed_ip}" "${CONNECTIONS_FILE}" | cut -f2 | head -n1 | xargs || true)
    [[ -n "${machine_name}" ]] && bouncer_name="${machine_name}"
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

  remove_allowed_range_apply() {
    echo "Сохранение central.env без ${removed_cidr}"
    save_env
    echo "Пересборка config.yaml LAPI"
    configure_docker_crowdsec_lapi
    echo "Обновление правил UFW"
    configure_ufw_full
    echo "Перезапуск контейнера CrowdSec"
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)
    if [[ -n "${machine_name}" ]]; then
      echo "Удаление machine ${machine_name} из CrowdSec LAPI"
      docker exec crowdsec cscli machines delete "${machine_name}" || true
      if [[ -n "${bouncer_name}" ]]; then
        echo "Удаление bouncer ${bouncer_name} из CrowdSec LAPI"
        docker exec crowdsec cscli bouncers delete "${bouncer_name}" || true
      fi
    fi
    if [[ -f "${CONNECTIONS_FILE}" && -n "${removed_ip}" ]]; then
      echo "Удаление строки ${removed_ip} из ${CONNECTIONS_FILE}"
      local tmp_file
      tmp_file=$(mktemp)
      grep -v "${removed_ip}" "${CONNECTIONS_FILE}" > "${tmp_file}" || true
      mv "${tmp_file}" "${CONNECTIONS_FILE}"
      chmod 600 "${CONNECTIONS_FILE}"
    fi
  }

  if ! run_with_live_progress "Удаление IP/CIDR ${removed_cidr}" remove_allowed_range_apply; then
    return 1
  fi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Успех " --msgbox "IP/CIDR удалён: ${removed_cidr}" 8 78
  else
    ok "IP/CIDR удалён: ${removed_cidr}"
    pause
  fi
}


replace_allowed_ranges() {
  safe_source_env
  local new_ranges
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    new_ranges=$(whiptail --title " Замена списка IP/CIDR " --inputbox "Текущий список: ${ALLOWED_RANGES:-пуст}\n\nВведите новый список через запятую:" 12 78 "${ALLOWED_RANGES}" 3>&1 1>&2 2>&3) || return 0
  else
    print_header
    echo "Сейчас: ${ALLOWED_RANGES:-список пуст}"
    echo "Введи новый список через запятую. Пусто закроет LAPI для удалённых IP."
    read -rp "Новый Allowed IP/CIDR: " new_ranges
  fi

  ALLOWED_RANGES="${new_ranges:-}"
  save_env
  configure_docker_crowdsec_lapi
  configure_ufw_full
  (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Успех " --msgbox "Список Allowed IP/CIDR обновлён." 8 78
  else
    ok "Список Allowed IP/CIDR обновлён."
    pause
  fi
}

change_lan_ip_or_web_port() {
  safe_source_env
  local new_lan_ip new_web_port
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    new_lan_ip=$(whiptail --title " Изменение LAN IP " --inputbox "Введите новый LAN IP:" 10 78 "${LAN_IP}" 3>&1 1>&2 2>&3) || return 0
    new_web_port=$(whiptail --title " Изменение порта Web UI " --inputbox "Введите новый порт веб-морды:" 10 78 "${WEB_PORT}" 3>&1 1>&2 2>&3) || return 0
  else
    print_header
    echo "Сейчас: LAN IP ${LAN_IP}, Web port ${WEB_PORT}, Web UI ${LOCAL_WEB_UI}"
    read -rp "Новый LAN IP [${LAN_IP}]: " new_lan_ip
    read -rp "Новый порт веб-морды [${WEB_PORT}]: " new_web_port
  fi

  if [[ -n "${new_web_port}" ]] && ! is_valid_port "${new_web_port}"; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
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
  install_or_update_crowdsec_manager
  configure_ufw_full

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Успех " --msgbox "Адрес веб-морды обновлён: ${LOCAL_WEB_UI}" 8 78
  else
    ok "Адрес веб-морды обновлён: ${LOCAL_WEB_UI}"
    pause
  fi
}

change_lapi_port() {
  safe_source_env
  local new_lapi_port
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    new_lapi_port=$(whiptail --title " Изменение порта LAPI " --inputbox "Введите новый порт LAPI:" 10 78 "${LAPI_PORT}" 3>&1 1>&2 2>&3) || return 0
  else
    print_header
    read -rp "Новый LAPI port [${LAPI_PORT}]: " new_lapi_port
    [[ -n "${new_lapi_port}" ]] || { warn "Порт не изменён."; pause; return; }
  fi

  if ! is_valid_port "${new_lapi_port}"; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
      whiptail --title " Ошибка " --msgbox "Некорректный порт: ${new_lapi_port}" 8 78
    else
      warn "Некорректный порт: ${new_lapi_port}"
      pause
    fi
    return
  fi

  LAPI_PORT="${new_lapi_port}"
  save_env
  install_or_update_crowdsec_manager
  configure_ufw_full

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Успех " --msgbox "Порт LAPI обновлён: ${LAPI_PORT}" 8 78
  else
    ok "Порт LAPI обновлён: ${LAPI_PORT}"
    pause
  fi
}

configure_public_lapi_url() {
  safe_source_env
  local new_url new_npm_cidr
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    new_url=$(whiptail --title " Публичный LAPI через Nginx Proxy Manager " --inputbox "Введите полный публичный URL LAPI, который проксируется через Nginx Proxy Manager.\n\nПример: https://lapi.example.com\n\nОставь пустым, чтобы отключить этот режим и вернуться к прямому http://IP:PORT." 14 92 "${PUBLIC_LAPI_URL:-}" 3>&1 1>&2 2>&3) || return 0
    if [[ -n "${new_url}" ]]; then
      new_npm_cidr=$(whiptail --title " Доступ NPM к LAPI " --inputbox "IP/CIDR Nginx Proxy Manager, которому разрешить доступ к локальному LAPI.\n\nПример: 192.168.1.10/32\nМожно оставить пустым, если NPM уже попадает в разрешённые локальные сети." 14 92 "${NPM_ALLOWED_CIDR:-}" 3>&1 1>&2 2>&3) || return 0
    else
      new_npm_cidr=""
    fi
  else
    print_header
    echo "Публичный LAPI через Nginx Proxy Manager"
    echo
    echo "Сейчас: ${PUBLIC_LAPI_URL:-не задан}"
    read -rp "Новый HTTPS URL LAPI через NPM или Enter чтобы отключить: " new_url
    if [[ -n "${new_url}" ]]; then
      read -rp "IP/CIDR Nginx Proxy Manager для доступа к LAPI [можно пусто]: " new_npm_cidr
    else
      new_npm_cidr=""
    fi
  fi

  new_url="${new_url%/}"
  if [[ -n "${new_url}" && ! "${new_url}" =~ ^https://[^[:space:]]+$ ]]; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
      whiptail --title " Ошибка " --msgbox "Для Nginx Proxy Manager нужен URL вида https://domain.example\n\nHTTP здесь не нужен: TLS должен завершаться на NPM." 10 84
    else
      warn "Для Nginx Proxy Manager нужен URL вида https://domain.example"
      pause
    fi
    return 1
  fi

  if [[ -n "${new_npm_cidr:-}" ]]; then
    new_npm_cidr="$(printf '%s' "${new_npm_cidr}" | tr -cd '0-9A-Fa-f:.\/')"
    if [[ ! "${new_npm_cidr}" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]; then
      if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
        whiptail --title " Ошибка " --msgbox "IP/CIDR NPM должен быть в формате 192.168.1.10/32 или IPv6/128." 9 84
      else
        warn "IP/CIDR NPM должен быть в формате 192.168.1.10/32 или IPv6/128."
        pause
      fi
      return 1
    fi
  fi

  PUBLIC_LAPI_URL="${new_url:-}"
  NPM_ALLOWED_CIDR="${new_npm_cidr:-}"
  if [[ -n "${PUBLIC_LAPI_URL}" ]]; then
    PUBLIC_LAPI_MODE="npm"
    PUBLIC_ADDR=""
    if [[ -n "${NPM_ALLOWED_CIDR}" && ! ",${ALLOWED_RANGES}," =~ ,${NPM_ALLOWED_CIDR}, ]]; then
      ALLOWED_RANGES="${ALLOWED_RANGES:+${ALLOWED_RANGES},}${NPM_ALLOWED_CIDR}"
    fi
  else
    PUBLIC_LAPI_MODE="direct"
    NPM_ALLOWED_CIDR=""
  fi

  save_env
  configure_docker_crowdsec_lapi || true
  configure_ufw_full || true

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Готово " --msgbox "LAPI URL для VPS теперь:\n${VPS_LAPI_URL}\n\nВ Nginx Proxy Manager Proxy Host должен вести на:\nhttp://${LAN_IP}:${LAPI_PORT}" 12 86
  else
    ok "LAPI URL для VPS: ${VPS_LAPI_URL}"
    echo "В Nginx Proxy Manager Proxy Host должен вести на: http://${LAN_IP}:${LAPI_PORT}"
    pause
  fi
}

crowdsec_cscli() {
  safe_source_env
  if [[ "${WEB_UI_TYPE:-manager}" == "manager" ]] && command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^crowdsec$'; then
    docker exec crowdsec cscli "$@"
  else
    cscli "$@"
  fi
}

machine_exists_on_central() {
  local machine_name="$1"
  crowdsec_cscli machines list 2>/dev/null | grep -Fq "${machine_name}"
}

validate_machine_on_central() {
  local machine_name="$1"
  [[ -n "${machine_name:-}" ]] || fail "Имя machine не может быть пустым."
  echo "Проверяю machine: ${machine_name}"
  crowdsec_cscli machines list || true
  echo
  echo "Подтверждаю machine: ${machine_name}"
  crowdsec_cscli machines validate "${machine_name}"
  ok "Machine подтверждена: ${machine_name}"
}

wait_for_machine_and_validate() {
  local machine_name="$1"
  local timeout="${2:-300}"
  local elapsed=0
  [[ -n "${machine_name:-}" ]] || fail "Имя machine не может быть пустым."
  echo "Ожидаю регистрацию machine '${machine_name}' на central LAPI."
  echo "Запусти vps.sh на VPS и вставь данные, которые показал мастер central."
  while (( elapsed < timeout )); do
    if machine_exists_on_central "${machine_name}"; then
      echo "Machine найдена: ${machine_name}"
      validate_machine_on_central "${machine_name}"
      return 0
    fi
    echo "Machine пока не появилась. Ожидание... ${elapsed}/${timeout} сек"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  fail "Machine '${machine_name}' не появилась за ${timeout} секунд. Позже подтверди её через меню: Подключения VPS и LAPI -> Подтвердить machine VPS."
}

machine_list_tsv() {
  local json_tmp text_tmp
  json_tmp="$(mktemp)"
  text_tmp="$(mktemp)"

  if crowdsec_cscli machines list -o json >"${json_tmp}" 2>/dev/null && [[ -s "${json_tmp}" ]]; then
    python3 - "${json_tmp}" <<'PY_JSON_MACHINES'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, 'r', encoding='utf-8', errors='replace'))
except Exception:
    data = []
if isinstance(data, dict):
    for key in ('machines', 'items', 'data'):
        if isinstance(data.get(key), list):
            data = data[key]
            break
if not isinstance(data, list):
    data = []
for item in data:
    if not isinstance(item, dict):
        continue
    name = str(item.get('machineId') or item.get('machine_id') or item.get('name') or item.get('login') or item.get('id') or '').strip()
    if not name:
        continue
    ip = str(item.get('ipAddress') or item.get('ip_address') or item.get('ip') or item.get('last_ip') or '-').strip() or '-'
    last = str(item.get('lastUpdate') or item.get('last_update') or item.get('updated_at') or item.get('last_seen') or '-').strip() or '-'
    version = str(item.get('version') or item.get('agent_version') or '-').strip() or '-'
    raw_valid = item.get('validated')
    if raw_valid is None:
        raw_valid = item.get('isValidated')
    if raw_valid is None:
        raw_valid = item.get('is_validated')
    if raw_valid is None:
        raw_valid = item.get('status')
    valid_text = str(raw_valid).strip().lower()
    validated = 'yes' if raw_valid is True or valid_text in ('true','yes','validated','valid','enabled','✔','✓','✅') else 'no'
    print('\t'.join([name, ip, last, validated, version]))
PY_JSON_MACHINES
    local rc=$?
    rm -f "${json_tmp}" "${text_tmp}"
    return "${rc}"
  fi

  crowdsec_cscli machines list >"${text_tmp}" 2>&1 || true
  python3 - "${text_tmp}" <<'PY_TEXT_MACHINES'
import re, sys
text = open(sys.argv[1], 'r', encoding='utf-8', errors='replace').read()
ansi = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]')
text = ansi.sub('', text)
for raw in text.splitlines():
    line = raw.strip()
    if not line or line.startswith('-') or line.lower().startswith('name'):
        continue
    if 'no machines' in line.lower() or 'error' in line.lower():
        continue
    parts = re.split(r'\s+', line)
    if len(parts) < 2:
        continue
    name = parts[0]
    if not re.match(r'^[A-Za-z0-9_.:-]+$', name):
        continue
    ip = parts[1] if len(parts) > 1 else '-'
    last = parts[2] if len(parts) > 2 else '-'
    validated = 'yes' if any(mark in line for mark in ('✔','✓','✅')) or re.search(r'\b(validated|true|yes)\b', line, re.I) else 'no'
    version = parts[-1] if len(parts) >= 5 else '-'
    print('\t'.join([name, ip, last, validated, version]))
PY_TEXT_MACHINES
  local rc=$?
  rm -f "${json_tmp}" "${text_tmp}"
  return "${rc}"
}

validate_selected_machines_apply() {
  local machines_file="$1"
  local selected_file="$2"
  local name ip last validated version changed=0
  while IFS=$'\t' read -r name ip last validated version; do
    [[ -n "${name:-}" ]] || continue
    if grep -Fxq "${name}" "${selected_file}"; then
      if [[ "${validated}" == "yes" ]]; then
        echo "Already validated: ${name}"
      else
        echo "Validating: ${name}"
        crowdsec_cscli machines validate "${name}"
        changed=$((changed + 1))
      fi
    fi
  done < "${machines_file}"
  if (( changed == 0 )); then
    echo "No new machines selected for validation."
  else
    echo "Validated machines: ${changed}"
  fi
}

validate_machine_prompt() {
  safe_source_env
  local machines_file selected_file removed_file selected_raw rc name ip last validated version state label changed_uncheck=0
  machines_file="$(mktemp)"
  selected_file="$(mktemp)"
  removed_file="$(mktemp)"
  machine_list_tsv >"${machines_file}" || true

  if [[ ! -s "${machines_file}" ]]; then
    rm -f "${machines_file}" "${selected_file}" "${removed_file}"
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
      whiptail --title " $(T "Machines на central" "Machines on central") " --msgbox "$(T "Machines не найдены." "No machines found.")" 8 76 || true
    else
      warn "$(T "Machines не найдены." "No machines found.")"
      pause
    fi
    return 0
  fi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    local args=()
    while IFS=$'\t' read -r name ip last validated version; do
      [[ -n "${name:-}" ]] || continue
      if [[ "${validated}" == "yes" ]]; then
        state="on"
        label="$(T "подтверждена" "validated") | ${ip:-'-'} | ${version:-'-'}"
      else
        state="off"
        label="$(T "не подтверждена" "not validated") | ${ip:-'-'} | ${version:-'-'}"
      fi
      args+=("${name}" "${label}" "${state}")
    done < "${machines_file}"

    set +e
    selected_raw="$(whiptail --title " $(T "Подтвердить machine VPS" "Validate VPS machines") " \
      --cancel-button "$(T "Отмена" "Cancel")" --ok-button "OK" --notags \
      --checklist "$(T "Отметь machines, которые должны быть подтверждены.\n\nOK - применить выбранные подтверждения.\nОтмена - вернуться назад без изменений." "Select machines that should be validated.\n\nOK - apply selected validations.\nCancel - go back without changes.")" \
      24 110 14 "${args[@]}" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    if [[ "${rc}" -ne 0 ]]; then
      rm -f "${machines_file}" "${selected_file}" "${removed_file}"
      return 0
    fi

    printf '%s\n' ${selected_raw} | tr -d '"' | awk 'NF && !seen[$0]++' >"${selected_file}"
  else
    print_header
    echo "$(T "Machines на central:" "Machines on central:")"
    echo
    nl -w2 -s') ' "${machines_file}" | awk -F'\t' '{status=($5=="yes"?"[x]":"[ ]"); print $1" "status" "$2" "$3" "$4" "$6}'
    echo
    echo "$(T "Введи имена machines для подтверждения через пробел. Enter - назад без изменений." "Enter machine names to validate separated by spaces. Enter - back without changes.")"
    read -rp "> " selected_raw || selected_raw=""
    if [[ -z "${selected_raw// }" ]]; then
      rm -f "${machines_file}" "${selected_file}" "${removed_file}"
      return 0
    fi
    printf '%s\n' ${selected_raw} | tr -cd 'A-Za-z0-9_.:-\n' | awk 'NF && !seen[$0]++' >"${selected_file}"
  fi

  while IFS=$'\t' read -r name ip last validated version; do
    [[ -n "${name:-}" ]] || continue
    if [[ "${validated}" == "yes" ]] && ! grep -Fxq "${name}" "${selected_file}"; then
      echo "${name}" >>"${removed_file}"
      changed_uncheck=1
    fi
  done < "${machines_file}"

  if [[ -s "${selected_file}" ]]; then
    run_with_live_progress "$(T "Подтверждение machines" "Validating machines")" validate_selected_machines_apply "${machines_file}" "${selected_file}" || true
  fi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    local msg
    msg="$(T "Изменения применены." "Changes applied.")"
    if (( changed_uncheck )); then
      msg="${msg}\n\n$(T "Снятие галочки с уже подтверждённой machine не удаляет её подтверждение. Для удаления machine используй отдельное удаление/перерегистрацию." "Unchecking an already validated machine does not remove its validation. To remove a machine, delete/re-register it separately.")"
    fi
    whiptail --title " $(T "Готово" "Done") " --msgbox "${msg}" 12 90 || true
  else
    ok "$(T "Изменения применены." "Changes applied.")"
    if (( changed_uncheck )); then
      warn "$(T "Снятие галочки с уже подтверждённой machine не удаляет её подтверждение." "Unchecking an already validated machine does not remove its validation.")"
    fi
    pause
  fi

  rm -f "${machines_file}" "${selected_file}" "${removed_file}"
  return 0
}

change_public_addr() {
  safe_source_env
  local new_public
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    new_public=$(whiptail --title " Внешний адрес LAPI " --inputbox "Текущий адрес: ${PUBLIC_ADDR:-не задан}\n\nВведите новый внешний IP или DNS (оставьте пустым, чтобы удалить):" 12 78 "${PUBLIC_ADDR}" 3>&1 1>&2 2>&3) || return 0
  else
    print_header
    echo "Сейчас: ${PUBLIC_ADDR:-не задан}"
    read -rp "Новый внешний адрес или Enter чтобы убрать: " new_public
  fi

  PUBLIC_ADDR="${new_public:-}"
  if [[ -n "${PUBLIC_ADDR}" ]]; then
    PUBLIC_LAPI_MODE="direct"
    PUBLIC_LAPI_URL=""
    NPM_ALLOWED_CIDR=""
  fi
  save_env

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Успех " --msgbox "Внешний адрес обновлён.\nLAPI URL для VPS: ${VPS_LAPI_URL}" 10 78
  else
    ok "Внешний адрес обновлён. LAPI URL для VPS: ${VPS_LAPI_URL}"
    pause
  fi
}

regenerate_auto_token() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Регенерация токена " --yes-button "$(T "Продолжить" "Continue")" --no-button "$(T "Отмена" "Cancel")" --yesno "Новые серверы должны будут использовать новый токен.\n\nПерегенерировать токен авторегистрации?" 12 78 || return 0
  else
    print_header
    echo "Новые серверы должны будут использовать новый токен."
    read -rp "Перегенерировать token? [y/N]: " confirm
    [[ "${confirm:-N}" =~ ^[Yy]$ ]] || { echo "Отменено."; pause; return; }
  fi

  AUTO_REG_TOKEN="$(openssl rand -hex 32)"
  save_env
  configure_docker_crowdsec_lapi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Успех " --msgbox "Auto-registration token обновлён." 8 78
  else
    ok "Auto-registration token обновлён."
    pause
  fi
}

regenerate_bouncer_key() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " Регенерация bouncer key " --yes-button "$(T "Продолжить" "Continue")" --no-button "$(T "Отмена" "Cancel")" --yesno "Удалённые bouncers нужно будет перенастроить на новый ключ.\n\nСоздать новый shared bouncer key?" 12 78 || return 0
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

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
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
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
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
  install_or_update_crowdsec_manager
  configure_ufw_full
}
reinstall_simple_web_ui() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
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
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
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
  WEB_UI_TYPE="manager"
  configure_docker_crowdsec_lapi
  create_or_update_shared_bouncer_key
  (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)
  configure_ufw_full
  install_menu_files
}
reapply_all_settings() {
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
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
  run_menu_step "Обновление CrowdSec в Docker" install_or_update_crowdsec_manager
}

update_web_ui_only() {
  run_menu_step "Обновление CrowdSec Manager" install_or_update_crowdsec_manager
}

update_installed_stack() {
  run_menu_step "Обновление Docker" install_or_update_docker
  run_menu_step "Обновление CrowdSec + Manager" install_or_update_crowdsec_manager
  run_menu_step "Настройка Firewall" configure_ufw_full
}

show_logs() {
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    echo "Логи CrowdSec Manager (последние 100 строк):"
    docker logs --tail 100 crowdsec-manager 2>&1 || true
    echo
    echo "Логи CrowdSec Docker (последние 100 строк):"
    docker logs --tail 100 crowdsec 2>&1 || true
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
    cmd="docker exec crowdsec cscli"
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
    echo; echo "CrowdSec Manager image:"; command -v docker >/dev/null 2>&1 && docker images "${MANAGER_IMAGE}" || true
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
    echo "Проверяю LAPI из контейнера CrowdSec Manager:"
    docker exec crowdsec-manager sh -lc "wget -qO- http://crowdsec:8080/health || curl -fsS http://crowdsec:8080/health" 2>&1 || true
  } >"${tmp}"
  show_file "Проверка LAPI" "${tmp}"
  rm -f "${tmp}"
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
checkbox=white,blue
actcheckbox=black,cyan
entry=white,blue
label=white,blue
listbox=white,blue
actlistbox=black,cyan
textbox=white,blue
'
}

ensure_tui_tools() {
  type -P dialog >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    log "Устанавливаю TUI-зависимости меню: dialog, whiptail, less..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || return 1
    apt-get install -y dialog whiptail less || return 1
  fi
  tui_available
}

tui_summary() {
  safe_source_env
  cat <<EOF
Web UI: ${LOCAL_WEB_UI}
LAPI:   ${VPS_LAPI_URL}
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
    public_lapi_url) configure_public_lapi_url ;;
    validate_machine) validate_machine_prompt ;;
    auto_token) regenerate_auto_token ;;
    bouncer_key) regenerate_bouncer_key ;;
    firewall) show_firewall; pause ;;
    test_lapi) test_webui_lapi; pause ;;
    restart) restart_services ;;
    update_webui) update_web_ui_only ;;
    logs) show_logs; pause ;;
    crowdsec_info) show_crowdsec_info; pause ;;
    reapply) reapply_all_settings ;;
    update_all) update_installed_stack ;;
    update_system) update_system_only ;;
    update_docker) update_docker_only ;;
    update_crowdsec) update_crowdsec_only ;;
    versions) show_versions; pause ;;
    disable_autostart) disable_login_menu ;;
    enable_autostart) enable_login_menu ;;
    repair_menu) repair_menu_installation ;;
    node_bouncer) create_named_vps_bouncer_key ;;
    device_manage) manage_bouncer_devices_menu ;;
    device_events) manage_device_events_menu ;;
    syslog_devices) show_remote_syslog_devices ;;
    language) change_language ;;
    protection_menu) manage_protection_menu ;;
    protection_baseline) run_with_live_progress "$(T "Базовая защита CrowdSec" "Base CrowdSec protection")" apply_initial_protection_baseline ;;
    protection_collections) manage_collections_menu ;;
    protection_decisions) manage_decisions_menu ;;
    protection_trusted) manage_trusted_ips_menu ;;
    protection_capi) capi_console_status ;;
    *) warn "$(T "Неизвестное действие меню." "Unknown menu action.")"; pause ;;
  esac
}

menu_loop_whiptail() {
  require_root
  tui_theme
  export CROWDSEC_TUI_MODE="whiptail"
  safe_clear
  while true; do
    local category choice summary
    summary="$(tui_summary)"
    category="$(whiptail \
      --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" \
      --title "$(T " CrowdSec Central " " CrowdSec Central ")" \
      --cancel-button "$(T "Назад" "Back")" \
      --ok-button "$(T "Выбрать" "Select")" \
      --notags \
      --menu "$(T "Выберите раздел:\nСтрелки - навигация, ENTER - выбрать, ESC/Отмена - назад.\n\n${summary}" "Choose a section:\nArrows - navigation, ENTER - select, ESC/Cancel - back.\n\n${summary}")" \
      24 96 9 \
      "status" "$(T "Статус и данные" "Status and data")" \
      "protection" "$(T "Защита, правила и decisions" "Protection, rules and decisions")" \
      "vps" "$(T "VPS nodes / machines" "VPS nodes / machines")" \
      "devices" "$(T "Bouncer/API устройства" "Bouncer/API devices")" \
      "events" "$(T "События от роутера/устройства" "Router/device events")" \
      "network" "$(T "Сеть, TLS и доступ к LAPI" "Network, TLS and LAPI access")" \
      "service" "$(T "Обслуживание и диагностика" "Maintenance and diagnostics")" \
      "menu" "$(T "Настройки меню" "Menu settings")" \
      "exit" "$(T "Выход" "Exit")" \
      3>&1 1>&2 2>&3)" || continue
    [[ "${category}" == "exit" ]] && exit 0

    while true; do
      case "${category}" in
        status)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "Статус и данные" "Status and data") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 18 82 5 \
            "status" "$(T "Статус сервисов и портов" "Service and port status")" \
            "connect" "$(T "Показать созданные подключения" "Show saved connections")" \
            "envfile" "$(T "Показать central.env" "Show central.env")" \
            "crowdsec_info" "$(T "Machines, bouncers, alerts, decisions" "Machines, bouncers, alerts, decisions")" \
            3>&1 1>&2 2>&3)" || break
          ;;
        protection)
          manage_protection_menu
          break
          ;;
        vps)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "VPS nodes / machines" "VPS nodes / machines") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 20 96 6 \
            "node_bouncer" "$(T "Создать подключение VPS: SSH или ручное" "Create VPS connection: SSH or manual")" \
            "validate_machine" "$(T "Подтвердить machine VPS" "Validate VPS machine")" \
            "connect" "$(T "Показать созданные подключения" "Show saved connections")" \
            "add_range" "$(T "Добавить IP/CIDR вручную" "Add IP/CIDR manually")" \
            "remove_range" "$(T "Удалить IP/CIDR из LAPI" "Remove IP/CIDR from LAPI")" \
            "replace_ranges" "$(T "Заменить весь список IP/CIDR" "Replace the full IP/CIDR list")" \
            3>&1 1>&2 2>&3)" || break
          ;;
        devices)
          manage_bouncer_devices_menu
          break
          ;;
        events)
          manage_device_events_menu
          break
          ;;
        network)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "Сеть, TLS и доступ к LAPI" "Network, TLS and LAPI access") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 22 90 8 \
            "web_addr" "$(T "Изменить LAN IP или порт Web UI" "Change LAN IP or Web UI port")" \
            "lapi_port" "$(T "Изменить порт LAPI" "Change LAPI port")" \
            "public_addr" "$(T "Изменить внешний IP/DDNS для прямого HTTP" "Change public IP/DDNS for direct HTTP")" \
            "public_lapi_url" "$(T "HTTPS LAPI через Nginx Proxy Manager" "HTTPS LAPI through Nginx Proxy Manager")" \
            "auto_token" "$(T "Перегенерировать auto-registration token" "Regenerate auto-registration token")" \
            "bouncer_key" "$(T "Перегенерировать shared bouncer key" "Regenerate shared bouncer key")" \
            "firewall" "$(T "Показать firewall/UFW" "Show firewall/UFW")" \
            "test_lapi" "$(T "Проверить доступ Web UI к LAPI" "Test Web UI access to LAPI")" \
            3>&1 1>&2 2>&3)" || break
          ;;
        service)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "Обслуживание и диагностика" "Maintenance and diagnostics") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 23 90 10 \
            "restart" "$(T "Перезапустить CrowdSec, Docker и Web UI" "Restart CrowdSec, Docker and Web UI")" \
            "update_webui" "$(T "Обновить CrowdSec Manager" "Update CrowdSec Manager")" \
            "logs" "$(T "Показать логи Manager и CrowdSec" "Show Manager and CrowdSec logs")" \
            "reapply" "$(T "Повторно применить все настройки" "Reapply all settings")" \
            "update_all" "$(T "Обновить весь стек" "Update full stack")" \
            "update_system" "$(T "Обновить пакеты Debian" "Update Debian packages")" \
            "update_docker" "$(T "Обновить Docker" "Update Docker")" \
            "update_crowdsec" "$(T "Обновить CrowdSec" "Update CrowdSec")" \
            "versions" "$(T "Показать версии ПО" "Show software versions")" \
            "syslog_devices" "$(T "Показать syslog intake" "Show syslog intake")" \
            3>&1 1>&2 2>&3)" || break
          ;;
        menu)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "Настройки меню" "Menu settings") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 18 82 5 \
            "disable_autostart" "$(T "Отключить автозапуск меню при входе" "Disable menu autostart on login")" \
            "enable_autostart" "$(T "Включить автозапуск меню при входе" "Enable menu autostart on login")" \
            "repair_menu" "$(T "Обновить или переустановить команду меню" "Update or reinstall menu command")" \
            "language" "$(T "Изменить язык интерфейса" "Change interface language")" \
            3>&1 1>&2 2>&3)" || break
          ;;
      esac
      run_menu_action "${choice}"
    done
  done
}

menu_loop_plain() {
  require_root
  safe_clear
  while true; do
    print_header
    safe_source_env
    echo "+----------------------------------------------------------+"
    printf "| %-56s |\n" "Web UI: ${LOCAL_WEB_UI}"
    printf "| %-56s |\n" "LAPI: ${VPS_LAPI_URL}"
    echo "+----------------------------------------------------------+"
    echo
    echo "$(T "[ СТАТУС ]" "[ STATUS ]")"
    echo "  1) $(T "Показать статус" "Show status")"
    echo "  2) $(T "Показать созданные подключения" "Show saved connections")"
    echo "  3) $(T "Показать central.env" "Show central.env")"
    echo "  4) $(T "Machines, bouncers, alerts, decisions" "Machines, bouncers, alerts, decisions")"
    echo
    echo "$(T "[ ЗАЩИТА, ПРАВИЛА, DECISIONS ]" "[ PROTECTION, RULES, DECISIONS ]")"
    echo "  5) $(T "Меню защиты" "Protection menu")"
    echo "  6) $(T "Базовая бесплатная защита" "Base free protection")"
    echo "  7) $(T "Collections / Hub / rules" "Collections / Hub / rules")"
    echo "  8) $(T "Manual decisions / local blacklist" "Manual decisions / local blacklist")"
    echo "  9) $(T "Доверенные IP/CIDR" "Trusted IP/CIDR")"
    echo
    echo "$(T "[ VPS / MACHINES ]" "[ VPS / MACHINES ]")"
    echo " 10) $(T "Создать подключение VPS" "Create VPS connection")"
    echo " 11) $(T "Подтвердить machine VPS" "Validate VPS machine")"
    echo " 12) $(T "Добавить IP/CIDR вручную" "Add IP/CIDR manually")"
    echo " 13) $(T "Удалить IP/CIDR из LAPI" "Remove IP/CIDR from LAPI")"
    echo " 14) $(T "Заменить список IP/CIDR" "Replace IP/CIDR list")"
    echo
    echo "$(T "[ BOUNCER/API УСТРОЙСТВА И СОБЫТИЯ ]" "[ BOUNCER/API DEVICES AND EVENTS ]")"
    echo " 15) $(T "Управление bouncer/API устройствами" "Manage bouncer/API devices")"
    echo " 16) $(T "События от роутера/устройства" "Router/device event intake")"
    echo " 17) $(T "Показать syslog intake" "Show syslog intake")"
    echo
    echo "$(T "[ СЕТЬ, TLS, КЛЮЧИ ]" "[ NETWORK, TLS, KEYS ]")"
    echo " 18) $(T "Изменить LAN IP или порт Web UI" "Change LAN IP or Web UI port")"
    echo " 19) $(T "Изменить порт LAPI" "Change LAPI port")"
    echo " 20) $(T "Изменить внешний IP/DDNS" "Change public IP/DDNS")"
    echo " 21) $(T "HTTPS LAPI через Nginx Proxy Manager" "HTTPS LAPI through Nginx Proxy Manager")"
    echo " 22) $(T "Перегенерировать auto-registration token" "Regenerate auto-registration token")"
    echo " 23) $(T "Перегенерировать shared bouncer key" "Regenerate shared bouncer key")"
    echo " 24) $(T "Показать firewall/UFW" "Show firewall/UFW")"
    echo " 25) $(T "Проверить Web UI -> LAPI" "Test Web UI -> LAPI")"
    echo
    echo "$(T "[ ОБСЛУЖИВАНИЕ ]" "[ MAINTENANCE ]")"
    echo " 26) $(T "Перезапустить CrowdSec, Docker и Web UI" "Restart CrowdSec, Docker and Web UI")"
    echo " 27) $(T "Обновить CrowdSec Manager" "Update CrowdSec Manager")"
    echo " 28) $(T "Показать логи Manager и CrowdSec" "Show Manager and CrowdSec logs")"
    echo " 29) $(T "Повторно применить все настройки" "Reapply all settings")"
    echo " 30) $(T "Обновить весь стек" "Update full stack")"
    echo " 31) $(T "Обновить пакеты Debian" "Update Debian packages")"
    echo " 32) $(T "Обновить Docker" "Update Docker")"
    echo " 33) $(T "Обновить CrowdSec" "Update CrowdSec")"
    echo " 34) $(T "Показать версии ПО" "Show software versions")"
    echo " 35) $(T "Починить или переустановить команду меню" "Repair or reinstall menu command")"
    echo " 36) $(T "Изменить язык интерфейса" "Change interface language")"
    echo " 37) $(T "Отключить автозапуск меню" "Disable menu autostart")"
    echo " 38) $(T "Включить автозапуск меню" "Enable menu autostart")"
    echo
    echo "  0) $(T "Выход" "Exit")"
    echo
    if ! read -rp "$(T "Выбери действие [0-38]: " "Choose action [0-38]: ")" choice; then
      echo
      continue
    fi
    case "${choice}" in
      1) show_status; pause ;;
      2) show_connection_info; pause ;;
      3) show_tokens_file; pause ;;
      4) show_crowdsec_info; pause ;;
      5) manage_protection_menu ;;
      6) run_with_live_progress "$(T "Базовая защита CrowdSec" "Base CrowdSec protection")" apply_initial_protection_baseline ;;
      7) manage_collections_menu ;;
      8) manage_decisions_menu ;;
      9) manage_trusted_ips_menu ;;
      10) create_named_vps_bouncer_key ;;
      11) validate_machine_prompt ;;
      12) add_allowed_range ;;
      13) remove_allowed_range ;;
      14) replace_allowed_ranges ;;
      15) manage_bouncer_devices_menu ;;
      16) manage_device_events_menu ;;
      17) show_remote_syslog_devices ;;
      18) change_lan_ip_or_web_port ;;
      19) change_lapi_port ;;
      20) change_public_addr ;;
      21) configure_public_lapi_url ;;
      22) regenerate_auto_token ;;
      23) regenerate_bouncer_key ;;
      24) show_firewall; pause ;;
      25) test_webui_lapi; pause ;;
      26) restart_services ;;
      27) update_web_ui_only ;;
      28) show_logs; pause ;;
      29) reapply_all_settings ;;
      30) update_installed_stack ;;
      31) update_system_only ;;
      32) update_docker_only ;;
      33) update_crowdsec_only ;;
      34) show_versions; pause ;;
      35) repair_menu_installation ;;
      36) change_language ;;
      37) disable_login_menu ;;
      38) enable_login_menu ;;
      0) exit 0 ;;
      *) echo "$(T "Неизвестный пункт меню." "Unknown menu item.")"; pause ;;
    esac
  done
}

menu_loop() {
  if [[ -t 0 && -t 1 ]] && ensure_tui_tools; then
    menu_loop_whiptail
  else
    warn "TUI-меню недоступно: нет TTY или не удалось установить dialog/whiptail. Открываю простой fallback."
    pause
    menu_loop_plain
  fi
}


# -----------------------------------------------------------------------------
# v0.6.7 device management overrides
# -----------------------------------------------------------------------------
# Важно: bouncer-only устройство не является machine и не отправляет события.
# Оно только забирает decisions из LAPI. События от роутера/устройства - это
# отдельная настройка удалённого log intake, включается и удаляется отдельно.

DEVICE_CONNECTION_TYPE="BOUNCER_ONLY_DEVICE"

crowdsec_cscli() {
  if [[ "${WEB_UI_TYPE:-simple}" == "manager" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
    docker exec crowdsec cscli "$@"
  else
    cscli "$@"
  fi
}

normalize_cidr_input() {
  local raw="${1:-}" ip cidr
  raw="$(printf '%s' "${raw}" | tr -cd '0-9A-Fa-f:.\/')"
  [[ -n "${raw}" ]] || return 1
  if [[ "${raw}" == */* ]]; then
    cidr="${raw}"
  elif [[ "${raw}" == *:* ]]; then
    cidr="${raw}/128"
  else
    cidr="${raw}/32"
  fi
  printf '%s' "${cidr}"
}

add_allowed_range_exact() {
  local cidr="$1"
  if [[ -z "${ALLOWED_RANGES:-}" ]]; then
    ALLOWED_RANGES="${cidr}"
  elif ! echo ",${ALLOWED_RANGES}," | grep -q ",${cidr},"; then
    ALLOWED_RANGES="${ALLOWED_RANGES},${cidr}"
  fi
}

remove_allowed_range_exact() {
  local target="$1" out="" old_ifs item
  old_ifs="${IFS}"
  IFS=','
  for item in ${ALLOWED_RANGES:-}; do
    IFS="${old_ifs}"
    item="$(echo "${item}" | xargs)"
    [[ -n "${item}" ]] || continue
    [[ "${item}" == "${target}" ]] && continue
    out="${out:+${out},}${item}"
    IFS=','
  done
  IFS="${old_ifs}"
  ALLOWED_RANGES="${out}"
}

record_connection_line() {
  local name="$1" ip="$2" lapi="$3" type="$4" key="$5"
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"
  touch "${CONNECTIONS_FILE}"
  chmod 600 "${CONNECTIONS_FILE}"
  awk -F'\t' -v name="${name}" '($2 != name)' "${CONNECTIONS_FILE}" >"${CONNECTIONS_FILE}.tmp" || true
  mv "${CONNECTIONS_FILE}.tmp" "${CONNECTIONS_FILE}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "${name}" "${ip}" "${lapi}" "${type}" "${key}" >>"${CONNECTIONS_FILE}"
}

select_bouncer_device_record() {
  local __var="$1" title="${2:-Bouncer/API devices}" lines=() line menu_args=() i name ip type choice
  [[ -s "${CONNECTIONS_FILE}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    type="$(printf '%s' "${line}" | cut -f5)"
    case "${type}" in
      BOUNCER_ONLY_DEVICE|BOUNCER_ONLY_OPENWRT) lines+=("${line}") ;;
    esac
  done < "${CONNECTIONS_FILE}"
  ((${#lines[@]} > 0)) || return 1

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    for i in "${!lines[@]}"; do
      name="$(printf '%s' "${lines[$i]}" | cut -f2)"
      ip="$(printf '%s' "${lines[$i]}" | cut -f3)"
      menu_args+=("$((i+1))" "${name} [${ip}]")
    done
    choice="$(whiptail --title " ${title} " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите устройство:" "Choose a device:")" 18 92 10 "${menu_args[@]}" 3>&1 1>&2 2>&3)" || return 1
  else
    echo
    echo "${title}:"
    for i in "${!lines[@]}"; do
      name="$(printf '%s' "${lines[$i]}" | cut -f2)"
      ip="$(printf '%s' "${lines[$i]}" | cut -f3)"
      echo "$((i+1))) ${name} [${ip}]"
    done
    read -rp "$(T "Номер устройства: " "Device number: ")" choice || return 1
  fi
  [[ "${choice}" =~ ^[0-9]+$ ]] || return 1
  ((choice >= 1 && choice <= ${#lines[@]})) || return 1
  printf -v "${__var}" '%s' "${lines[$((choice-1))]}"
}

create_openwrt_bouncer_connection() {
  safe_source_env
  local name_raw cidr_raw lapi_url_raw rc tmp
  local node_name router_cidr vps_ip bouncer_key default_lapi

  default_lapi="${LOCAL_LAPI_URL}"
  [[ -n "${PUBLIC_LAPI_URL:-}" ]] && default_lapi="${VPS_LAPI_URL}"

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    set +e
    name_raw="$(whiptail --title " $(T "Bouncer/API device" "Bouncer/API device") " --inputbox "$(T "Имя устройства / bouncer name.\n\nНапример: openwrt-router, home-router, gateway-1, edge-bouncer.\nЭто имя будет видно в CrowdSec Manager только в списке bouncers." "Device name / bouncer name.\n\nExample: openwrt-router, home-router, gateway-1, edge-bouncer.\nThis name will be visible in CrowdSec Manager only in the bouncers list.")" 14 94 "bouncer-device" 3>&1 1>&2 2>&3)"
    rc=$?; set -e; [[ "${rc}" -eq 0 ]] || return 0
    set +e
    cidr_raw="$(whiptail --title " $(T "Device IP/CIDR" "Device IP/CIDR") " --inputbox "$(T "IP или CIDR устройства, которому разрешить доступ к LAPI.\n\nДля роутера в LAN обычно: 192.168.1.1/32.\nЭто не включает сбор логов. Это только доступ bouncer к LAPI." "Device IP or CIDR allowed to access LAPI.\n\nFor a router in LAN usually: 192.168.1.1/32.\nThis does not enable log collection. This is only LAPI access for the bouncer.")" 15 96 "" 3>&1 1>&2 2>&3)"
    rc=$?; set -e; [[ "${rc}" -eq 0 ]] || return 0
    set +e
    lapi_url_raw="$(whiptail --title " $(T "Bouncer/API LAPI URL" "Bouncer/API LAPI URL") " --inputbox "$(T "Какой LAPI URL прописать на устройстве?\n\nДля LAN обычно:\n${LOCAL_LAPI_URL}\n\nЧерез NPM/TLS:\n${VPS_LAPI_URL}" "Which LAPI URL should be configured on the device?\n\nFor LAN usually:\n${LOCAL_LAPI_URL}\n\nThrough NPM/TLS:\n${VPS_LAPI_URL}")" 17 96 "${default_lapi}" 3>&1 1>&2 2>&3)"
    rc=$?; set -e; [[ "${rc}" -eq 0 ]] || return 0
    whiptail --title " $(T "Подтверждение" "Confirmation") " --yes-button "$(T "Создать" "Create")" --no-button "$(T "Отмена" "Cancel")" --yesno "$(T "Будет создан только bouncer key и доступ к LAPI.\n\nУстройство появится в CrowdSec Manager в разделе Bouncers.\nВ Machines, Alerts и Events оно не появится, пока отдельно не включён сбор событий/логов.\n\nПродолжить?" "Only a bouncer key and LAPI access will be created.\n\nThe device will appear in CrowdSec Manager under Bouncers.\nIt will not appear in Machines, Alerts or Events unless event/log intake is configured separately.\n\nContinue?")" 16 94 || return 0
  else
    read -rp "$(T "Имя устройства / bouncer name [bouncer-device]: " "Device / bouncer name [bouncer-device]: ")" name_raw || return 0
    name_raw="${name_raw:-bouncer-device}"
    read -rp "$(T "IP/CIDR устройства для доступа к LAPI, например 192.168.1.1/32: " "Device IP/CIDR for LAPI access, e.g. 192.168.1.1/32: ")" cidr_raw || return 0
    read -rp "$(T "LAPI URL для устройства [${default_lapi}]: " "LAPI URL for device [${default_lapi}]: ")" lapi_url_raw || return 0
    lapi_url_raw="${lapi_url_raw:-${default_lapi}}"
  fi

  node_name="$(printf '%s' "${name_raw:-}" | tr -cd 'A-Za-z0-9._:-')"
  [[ -n "${node_name}" ]] || fail "$(T "Имя bouncer не может быть пустым." "Bouncer name cannot be empty.")"
  router_cidr="$(normalize_cidr_input "${cidr_raw:-}")" || fail "$(T "IP/CIDR устройства не может быть пустым." "Device IP/CIDR cannot be empty.")"
  vps_ip="${router_cidr%%/*}"
  lapi_url_raw="${lapi_url_raw%/}"
  [[ "${lapi_url_raw}" =~ ^https?://[^[:space:]]+$ ]] || fail "$(T "LAPI URL должен начинаться с http:// или https://" "LAPI URL must start with http:// or https://")"

  add_allowed_range_exact "${router_cidr}"
  bouncer_key="$(openssl rand -hex 32)"

  create_bouncer_device_apply() {
    echo "Удаление старого bouncer: ${node_name}"
    crowdsec_cscli bouncers delete "${node_name}" || true
    echo "Регистрация bouncer/API device: ${node_name}"
    crowdsec_cscli bouncers add "${node_name}" --key "${bouncer_key}"
    echo "Сохранение central.env"
    save_env
    echo "Обновление config.yaml CrowdSec LAPI"
    configure_docker_crowdsec_lapi
    echo "Перезапуск CrowdSec"
    restart_crowdsec_runtime || true
    echo "Обновление UFW"
    configure_ufw_full
    echo "Запись подключения"
    record_connection_line "${node_name}" "${vps_ip}" "${lapi_url_raw}" "${DEVICE_CONNECTION_TYPE}" "${bouncer_key}"
  }

  run_with_live_progress "$(T "Регистрация bouncer/API device" "Registering bouncer/API device")" create_bouncer_device_apply || return 1

  tmp="$(mktemp)"
  {
    echo "$(T "Данные для подключения устройства с bouncer/API:" "Bouncer/API device connection data:")"
    echo
    echo "Bouncer name: ${node_name}"
    echo "Allowed IP/CIDR: ${router_cidr}"
    echo "API URL: ${lapi_url_raw}/"
    echo "API key: ${bouncer_key}"
    echo
    echo "$(T "Важно:" "Important:")"
    echo "- $(T "Это bouncer-only устройство. Validate не нужен." "This is a bouncer-only device. No validate is required.")"
    echo "- $(T "Оно видно в CrowdSec Manager только в разделе Bouncers." "It is visible in CrowdSec Manager only under Bouncers.")"
    echo "- $(T "События/логи не появятся, пока отдельно не включён intake событий." "Events/logs will not appear unless event intake is configured separately.")"
    echo
    echo "LuCI / generic settings:"
    echo "enabled=1"
    echo "api_url=${lapi_url_raw}/"
    echo "api_key=${bouncer_key}"
    echo
    echo "OpenWrt UCI variant 1 (/etc/config/crowdsec):"
    echo "uci set crowdsec.@bouncer[0].enabled='1'"
    echo "uci set crowdsec.@bouncer[0].api_url='${lapi_url_raw}/'"
    echo "uci set crowdsec.@bouncer[0].api_key='${bouncer_key}'"
    echo "uci commit crowdsec"
    echo "/etc/init.d/crowdsec-firewall-bouncer restart"
    echo
    echo "OpenWrt UCI variant 2 (/etc/config/crowdsec-firewall-bouncer):"
    echo "uci set crowdsec-firewall-bouncer.@bouncer[0].enabled='1'"
    echo "uci set crowdsec-firewall-bouncer.@bouncer[0].api_url='${lapi_url_raw}/'"
    echo "uci set crowdsec-firewall-bouncer.@bouncer[0].api_key='${bouncer_key}'"
    echo "uci commit crowdsec-firewall-bouncer"
    echo "/etc/init.d/crowdsec-firewall-bouncer restart"
  } >"${tmp}"
  show_file "$(T "Bouncer/API device" "Bouncer/API device")" "${tmp}"
  rm -f "${tmp}"
}

show_connection_info() {
  safe_source_env
  local tmp
  tmp="$(mktemp)"
  {
    echo "$(T "Сохранённые подключения:" "Saved connections:")"
    echo
    if [[ -s "${CONNECTIONS_FILE}" ]]; then
      awk -F'\t' 'BEGIN {printf "%-20s %-24s %-18s %-42s %-22s\n", "TYPE", "NAME", "IP", "LAPI", "CREATED"} {printf "%-20s %-24s %-18s %-42s %-22s\n", $5, $2, $3, $4, $1}' "${CONNECTIONS_FILE}"
    else
      echo "$(T "Пока нет сохранённых подключений." "No saved connections yet.")"
    fi
    echo
    echo "$(T "Пояснение:" "Note:")"
    echo "- VPS machine появляется в Machines и требует validate."
    echo "- Bouncer/API device появляется только в Bouncers и validate не требует."
  } >"${tmp}"
  show_file "$(T "Подключения" "Connections")" "${tmp}"
  rm -f "${tmp}"
}

show_bouncer_devices() {
  safe_source_env
  local tmp
  tmp="$(mktemp)"
  {
    echo "$(T "Bouncer/API устройства, сохранённые скриптом:" "Bouncer/API devices saved by the script:")"
    echo
    if [[ -s "${CONNECTIONS_FILE}" ]]; then
      awk -F'\t' '$5=="BOUNCER_ONLY_DEVICE" || $5=="BOUNCER_ONLY_OPENWRT" {found=1; printf "%-24s %-20s %-42s %-22s\n", $2, $3, $4, $1} END {if (!found) print "нет сохранённых bouncer-only устройств"}' "${CONNECTIONS_FILE}"
    else
      echo "$(T "Пока нет устройств." "No devices yet.")"
    fi
    echo
    echo "$(T "Текущий список bouncers в CrowdSec:" "Current CrowdSec bouncers list:")"
    echo
    crowdsec_cscli bouncers list 2>&1 || true
  } >"${tmp}"
  show_file "$(T "Bouncer/API устройства" "Bouncer/API devices")" "${tmp}"
  rm -f "${tmp}"
}

remove_bouncer_device() {
  safe_source_env
  local rec name ip cidr key tmp
  if ! select_bouncer_device_record rec "$(T "Удалить bouncer/API устройство" "Remove bouncer/API device")"; then
    if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
      whiptail --title " $(T "Удаление" "Removal") " --msgbox "$(T "Нет bouncer/API устройств для удаления." "No bouncer/API devices to remove.")" 8 80 || true
    fi
    return 0
  fi
  name="$(printf '%s' "${rec}" | cut -f2)"
  ip="$(printf '%s' "${rec}" | cut -f3)"
  key="$(printf '%s' "${rec}" | cut -f6)"
  if [[ "${ip}" == *:* ]]; then cidr="${ip}/128"; else cidr="${ip}/32"; fi

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " $(T "Удаление" "Removal") " --yes-button "$(T "Удалить" "Remove")" --no-button "$(T "Отмена" "Cancel")" --yesno "$(T "Удалить bouncer, запись подключения и IP/CIDR из LAPI/UFW?" "Remove bouncer, connection record and IP/CIDR from LAPI/UFW?")\n\n${name} [${ip}]" 12 88 || return 0
  fi

  remove_bouncer_device_apply() {
    echo "Удаление bouncer ${name}"
    crowdsec_cscli bouncers delete "${name}" || true
    echo "Удаление записи подключения"
    awk -F'\t' -v name="${name}" '($2 != name)' "${CONNECTIONS_FILE}" >"${CONNECTIONS_FILE}.tmp" || true
    mv "${CONNECTIONS_FILE}.tmp" "${CONNECTIONS_FILE}"
    echo "Удаление event intake записи, если была"
    if [[ -f "${SYSLOG_DEVICES_FILE}" ]]; then
      awk -F'\t' -v name="${name}" '($1 != name)' "${SYSLOG_DEVICES_FILE}" >"${SYSLOG_DEVICES_FILE}.tmp" || true
      mv "${SYSLOG_DEVICES_FILE}.tmp" "${SYSLOG_DEVICES_FILE}"
    fi
    echo "Удаление ${cidr} из ALLOWED_RANGES"
    remove_allowed_range_exact "${cidr}"
    save_env
    configure_docker_crowdsec_lapi
    restart_crowdsec_runtime || true
    configure_ufw_full
  }
  run_with_live_progress "$(T "Удаление bouncer/API device" "Removing bouncer/API device")" remove_bouncer_device_apply || return 1
}

check_bouncer_device_status() {
  safe_source_env
  local tmp
  tmp="$(mktemp)"
  {
    echo "$(T "Статус bouncer/API устройств:" "Bouncer/API device status:")"
    echo
    crowdsec_cscli bouncers list 2>&1 || true
    echo
    echo "$(T "Если Last API pull обновляется, устройство подключено к LAPI. События это не показывает: bouncer не отправляет логи." "If Last API pull updates, the device is connected to LAPI. This does not show events: a bouncer does not send logs.")"
  } >"${tmp}"
  show_file "$(T "Статус bouncers" "Bouncer status")" "${tmp}"
  rm -f "${tmp}"
}

configure_device_event_intake() {
  safe_source_env
  local rec name ip cidr port proto mode tmp
  if ! select_bouncer_device_record rec "$(T "Включить события от устройства" "Enable device event intake")"; then return 0; fi
  name="$(printf '%s' "${rec}" | cut -f2)"
  ip="$(printf '%s' "${rec}" | cut -f3)"
  if [[ "${ip}" == *:* ]]; then cidr="${ip}/128"; else cidr="${ip}/32"; fi
  port="${DEFAULT_REMOTE_SYSLOG_PORT}"
  proto="both"
  mode="filtered"

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    mode="$(whiptail --title " $(T "Режим логов устройства" "Device log mode") " \
      --cancel-button "$(T "Отмена" "Cancel")" --ok-button "$(T "Выбрать" "Select")" --notags \
      --menu "$(T "Выберите режим.\n\nFiltered security events - рекомендуемый режим. Устройство отправляет копию syslog на central, но central пишет в CrowdSec только security/firewall/auth строки. Локальный logread на OpenWrt остаётся.\n\nFull diagnostic syslog - весь syslog пишется только в диагностический файл, а CrowdSec всё равно читает только filtered security файл." "Choose mode.\n\nFiltered security events - recommended. The device sends a syslog copy to central, but central writes only security/firewall/auth lines to CrowdSec. Local OpenWrt logread remains.\n\nFull diagnostic syslog - full syslog is written only to a diagnostic file, while CrowdSec still reads only the filtered security file.")" \
      22 100 2 \
      "filtered" "$(T "Только security/firewall/auth события для CrowdSec" "Only security/firewall/auth events for CrowdSec")" \
      "full" "$(T "Filtered для CrowdSec + полный диагностический лог отдельно" "Filtered for CrowdSec + separate full diagnostic log")" \
      3>&1 1>&2 2>&3)" || return 0

    port="$(whiptail --title " $(T "Syslog порт" "Syslog port") " --inputbox "$(T "Порт syslog на central.\n\n5140 выбран специально, чтобы не занимать привилегированный 514." "Syslog port on central.\n\n5140 is used to avoid the privileged 514 port.")" 11 86 "${DEFAULT_REMOTE_SYSLOG_PORT}" 3>&1 1>&2 2>&3)" || return 0

    whiptail --title " $(T "Подтверждение" "Confirmation") " --yes-button "$(T "Включить" "Enable")" --no-button "$(T "Отмена" "Cancel")" --yesno "$(T "Скрипт настроит central на приём копии syslog от выбранного устройства.\n\nПо умолчанию в CrowdSec попадут только отфильтрованные security/firewall/auth события. Весь лог НЕ будет читаться CrowdSec.\n\nСкрипт НЕ меняет роутер автоматически, а только покажет команды UCI." "The script will configure central to receive a syslog copy from the selected device.\n\nBy default only filtered security/firewall/auth events go to CrowdSec. The full log is NOT read by CrowdSec.\n\nThe script does NOT change the router automatically, it only shows UCI commands.")" 17 96 || return 0
  else
    echo "$(T "Режим логов:" "Log mode:")"
    echo "1) filtered - $(T "только security/firewall/auth события для CrowdSec" "only security/firewall/auth events for CrowdSec")"
    echo "2) full - $(T "filtered для CrowdSec + полный диагностический лог отдельно" "filtered for CrowdSec + separate full diagnostic log")"
    read -rp "$(T "Выбор [1/2]: " "Choice [1/2]: ")" mode || return 0
    case "${mode}" in 2|full) mode="full" ;; *) mode="filtered" ;; esac
    read -rp "$(T "Syslog port на central [${DEFAULT_REMOTE_SYSLOG_PORT}]: " "Syslog port on central [${DEFAULT_REMOTE_SYSLOG_PORT}]: ")" port || return 0
    port="${port:-${DEFAULT_REMOTE_SYSLOG_PORT}}"
  fi

  port="$(printf '%s' "${port}" | tr -cd '0-9')"
  is_valid_port "${port}" || fail "$(T "Некорректный syslog port." "Invalid syslog port.")"
  case "${mode}" in filtered|full) ;; *) mode="filtered" ;; esac

  configure_device_event_intake_apply() {
    record_remote_syslog_device "${name}" "${cidr}" "${port}" "${proto}" "${mode}"
    install_or_update_remote_syslog_receiver "${port}" "${proto}" "${mode}"
    configure_ufw_full
  }
  run_with_live_progress "$(T "Настройка filtered intake событий" "Configuring filtered event intake")" configure_device_event_intake_apply || return 1

  tmp="$(mktemp)"
  {
    echo "$(T "Intake событий включён на central." "Event intake enabled on central.")"
    echo
    echo "Device: ${name}"
    echo "Allowed IP/CIDR: ${cidr}"
    echo "Mode: ${mode}"
    echo "Central syslog host: ${LAN_IP}"
    echo "Central syslog port: ${port}"
    echo
    echo "$(T "Как это работает:" "How it works:")"
    echo "$(T "OpenWrt отправляет КОПИЮ syslog на central. Локальный logread на OpenWrt остаётся. Central фильтрует поток и отдаёт CrowdSec только security/firewall/auth события." "OpenWrt sends a syslog COPY to central. Local OpenWrt logread remains. Central filters the stream and gives CrowdSec only security/firewall/auth events.")"
    echo
    echo "OpenWrt 25 отправка syslog copy на central:"
    echo "uci set system.@system[0].log_ip='${LAN_IP}'"
    echo "uci set system.@system[0].log_port='${port}'"
    echo "uci set system.@system[0].log_proto='udp'"
    echo "uci commit system"
    echo "/etc/init.d/log restart"
    echo
    echo "OpenWrt 25 отключить remote syslog обратно:"
    echo "uci delete system.@system[0].log_ip 2>/dev/null"
    echo "uci delete system.@system[0].log_port 2>/dev/null"
    echo "uci delete system.@system[0].log_proto 2>/dev/null"
    echo "uci commit system"
    echo "/etc/init.d/log restart"
    echo
    echo "Filtered log for CrowdSec:"
    echo "sudo tail -f ${REMOTE_SYSLOG_DIR}/${ip}.security.log"
    if [[ "${mode}" == "full" ]]; then
      echo
      echo "Full diagnostic log, NOT read by CrowdSec:"
      echo "sudo tail -f ${REMOTE_SYSLOG_DIAG_DIR}/${ip}.full.log"
    fi
    echo
    echo "CrowdSec check:"
    echo "sudo docker exec crowdsec cscli metrics"
  } >"${tmp}"
  show_file "$(T "События от устройства" "Device events")" "${tmp}"
  rm -f "${tmp}"
}

disable_device_event_intake() {
  safe_source_env
  local rec name ip cidr
  if ! select_bouncer_device_record rec "$(T "Отключить события от устройства" "Disable device event intake")"; then return 0; fi
  name="$(printf '%s' "${rec}" | cut -f2)"
  ip="$(printf '%s' "${rec}" | cut -f3)"
  if [[ "${ip}" == *:* ]]; then cidr="${ip}/128"; else cidr="${ip}/32"; fi
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    whiptail --title " $(T "Отключить intake" "Disable intake") " --yes-button "$(T "Отключить" "Disable")" --no-button "$(T "Отмена" "Cancel")" --yesno "$(T "Отключить syslog intake для устройства?\n\nЭто удалит запись из списка intake и пересоберёт UFW. Настройку отправки логов на самом роутере нужно удалить отдельно." "Disable syslog intake for the device?\n\nThis removes the intake record and rebuilds UFW. Log forwarding on the router itself must be removed separately.")\n\n${name} [${cidr}]" 14 92 || return 0
  fi
  disable_device_event_intake_apply() {
    if [[ -f "${SYSLOG_DEVICES_FILE}" ]]; then
      awk -F'\t' -v name="${name}" '($1 != name)' "${SYSLOG_DEVICES_FILE}" >"${SYSLOG_DEVICES_FILE}.tmp" || true
      mv "${SYSLOG_DEVICES_FILE}.tmp" "${SYSLOG_DEVICES_FILE}"
    fi
        if [[ ! -s "${SYSLOG_DEVICES_FILE}" ]]; then
      rm -f /etc/rsyslog.d/30-crowdsec-remote-devices.conf /etc/logrotate.d/crowdsec-remote-devices
      rm -f "$(get_crowdsec_config_dir)/acquis.d/remote-syslog-devices.yaml" 2>/dev/null || true
      systemctl restart rsyslog 2>/dev/null || true
      restart_crowdsec_runtime || true
    else
      local first_port first_proto first_mode
      IFS=$'\t' read -r _ _ first_port first_proto first_mode _ < "${SYSLOG_DEVICES_FILE}" || true
      install_or_update_remote_syslog_receiver "${first_port:-${DEFAULT_REMOTE_SYSLOG_PORT}}" "${first_proto:-both}" "${first_mode:-filtered}"
    fi
    configure_ufw_full
  }
  run_with_live_progress "$(T "Отключение intake событий" "Disabling event intake")" disable_device_event_intake_apply || return 1
}

show_device_event_logs() {
  safe_source_env
  local rec name ip tmp
  if ! select_bouncer_device_record rec "$(T "Просмотр событий устройства" "View device events")"; then return 0; fi
  name="$(printf '%s' "${rec}" | cut -f2)"
  ip="$(printf '%s' "${rec}" | cut -f3)"
  tmp="$(mktemp)"
  {
    echo "Device: ${name} [${ip}]"
    echo
    echo "Filtered security/firewall/auth log for CrowdSec: ${REMOTE_SYSLOG_DIR}/${ip}.security.log"
    echo
    if [[ -f "${REMOTE_SYSLOG_DIR}/${ip}.security.log" ]]; then
      echo "Last 120 filtered lines:"
      tail -n 120 "${REMOTE_SYSLOG_DIR}/${ip}.security.log"
    else
      echo "$(T "Filtered файл логов пока не найден. Проверь, что устройство отправляет syslog на central, UFW разрешает порт, и в логе есть security/firewall/auth события." "Filtered log file not found yet. Check that the device sends syslog to central, UFW allows the port, and the log contains security/firewall/auth events.")"
    fi
    echo
    echo "Full diagnostic log, if enabled: ${REMOTE_SYSLOG_DIAG_DIR}/${ip}.full.log"
    if [[ -f "${REMOTE_SYSLOG_DIAG_DIR}/${ip}.full.log" ]]; then
      echo
      echo "Last 60 diagnostic lines:"
      tail -n 60 "${REMOTE_SYSLOG_DIAG_DIR}/${ip}.full.log"
    fi
    echo
    echo "CrowdSec metrics:"
    crowdsec_cscli metrics 2>&1 || true
  } >"${tmp}"
  show_file "$(T "События устройства" "Device events")" "${tmp}"
  rm -f "${tmp}"
}


trusted_ip_is_listed() {
  local value="$1"
  [[ -s "${TRUSTED_IP_FILE}" ]] || return 1
  awk -F'\t' -v v="${value}" '($1==v){found=1} END{exit found?0:1}' "${TRUSTED_IP_FILE}"
}

show_trusted_ip_list() {
  local tmp
  tmp="$(mktemp)"
  {
    echo "$(T "Локальный список доверенных IP/CIDR скрипта:" "Script local trusted IP/CIDR list:")"
    echo
    if [[ -s "${TRUSTED_IP_FILE}" ]]; then
      awk -F'\t' 'BEGIN {printf "%-32s %-24s %s\n", "IP/CIDR", "ADDED", "COMMENT"} {printf "%-32s %-24s %s\n", $1, $2, $3}' "${TRUSTED_IP_FILE}"
    else
      echo "$(T "Список пуст." "The list is empty.")"
    fi
    echo
    echo "$(T "Важно: это защитный список для действий скрипта и ручных decisions. Он не заменяет полноценные allowlists CrowdSec Console/CAPI. Скрипт не будет добавлять manual ban для значений из этого списка и может удалить активные decisions для них." "Important: this is a safety list for script actions and manual decisions. It does not replace full CrowdSec Console/CAPI allowlists. The script will not add manual bans for values in this list and can delete active decisions for them.")"
  } >"${tmp}"
  show_file "$(T "Доверенные IP/CIDR" "Trusted IP/CIDR")" "${tmp}"
  rm -f "${tmp}"
}

add_trusted_ip() {
  local value comment tmp
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    value="$(whiptail --title " $(T "Доверенный IP/CIDR" "Trusted IP/CIDR") " --inputbox "$(T "IP или CIDR, который скрипт не должен банить вручную.\n\nНапример: 192.168.1.1 или 192.168.1.0/24" "IP or CIDR that the script must not manually ban.\n\nExample: 192.168.1.1 or 192.168.1.0/24")" 12 86 "" 3>&1 1>&2 2>&3)" || return 0
    comment="$(whiptail --title " $(T "Комментарий" "Comment") " --inputbox "$(T "Комментарий, например: router, npm, home-vpn" "Comment, for example: router, npm, home-vpn")" 10 86 "" 3>&1 1>&2 2>&3)" || return 0
  else
    read -rp "$(T "IP/CIDR: " "IP/CIDR: ")" value || return 0
    read -rp "$(T "Комментарий: " "Comment: ")" comment || true
  fi
  value="$(printf '%s' "${value:-}" | tr -cd '0-9A-Fa-f:.\/')"
  [[ -n "${value}" ]] || fail "$(T "IP/CIDR не может быть пустым." "IP/CIDR cannot be empty.")"
  comment="$(printf '%s' "${comment:-}" | tr -cd 'A-Za-z0-9А-Яа-яёЁ ._:@/%+=,-')"
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"
  touch "${TRUSTED_IP_FILE}"
  chmod 600 "${TRUSTED_IP_FILE}"
  tmp="$(mktemp)"
  awk -F'\t' -v v="${value}" '($1!=v)' "${TRUSTED_IP_FILE}" >"${tmp}" || true
  mv "${tmp}" "${TRUSTED_IP_FILE}"
  printf '%s\t%s\t%s\n' "${value}" "$(date -Is)" "${comment}" >>"${TRUSTED_IP_FILE}"
  ok "$(T "Доверенный IP/CIDR сохранён." "Trusted IP/CIDR saved.")"
}

remove_trusted_ip() {
  local lines=() line choice tmp i value
  [[ -s "${TRUSTED_IP_FILE}" ]] || { warn "$(T "Список доверенных IP/CIDR пуст." "Trusted IP/CIDR list is empty.")"; pause; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] && lines+=("${line}")
  done < "${TRUSTED_IP_FILE}"
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    local args=()
    for i in "${!lines[@]}"; do
      args+=("$((i+1))" "$(printf '%s' "${lines[$i]}" | cut -f1,3 | tr '\t' ' ')")
    done
    choice="$(whiptail --title " $(T "Удалить доверенный IP/CIDR" "Remove trusted IP/CIDR") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Удалить" "Remove")" --notags --menu "$(T "Выберите запись:" "Choose an entry:")" 18 92 10 "${args[@]}" 3>&1 1>&2 2>&3)" || return 0
  else
    for i in "${!lines[@]}"; do echo "$((i+1))) ${lines[$i]}"; done
    read -rp "$(T "Номер: " "Number: ")" choice || return 0
  fi
  [[ "${choice}" =~ ^[0-9]+$ ]] || return 0
  ((choice >= 1 && choice <= ${#lines[@]})) || return 0
  value="$(printf '%s' "${lines[$((choice-1))]}" | cut -f1)"
  tmp="$(mktemp)"
  awk -F'\t' -v v="${value}" '($1!=v)' "${TRUSTED_IP_FILE}" >"${tmp}" || true
  mv "${tmp}" "${TRUSTED_IP_FILE}"
  ok "$(T "Запись удалена." "Entry removed.")"
}

remove_decisions_for_trusted_ips() {
  local value
  [[ -s "${TRUSTED_IP_FILE}" ]] || { warn "$(T "Список доверенных IP/CIDR пуст." "Trusted IP/CIDR list is empty.")"; return 0; }
  while IFS=$'\t' read -r value _ _; do
    [[ -n "${value:-}" ]] || continue
    echo "Remove decisions for trusted: ${value}"
    if [[ "${value}" == */* ]]; then
      crowdsec_cscli decisions delete --range "${value}" || true
    else
      crowdsec_cscli decisions delete --ip "${value}" || true
    fi
  done < "${TRUSTED_IP_FILE}"
}

protection_install_collection_group() {
  local group="${1:-base}" col
  echo "CrowdSec Hub update..."
  crowdsec_cscli hub update || true
  case "${group}" in
    base)
      set -- crowdsecurity/linux crowdsecurity/sshd
      ;;
    router)
      set -- crowdsecurity/linux crowdsecurity/sshd crowdsecurity/iptables
      ;;
    web)
      set -- crowdsecurity/linux crowdsecurity/sshd crowdsecurity/nginx crowdsecurity/apache2 crowdsecurity/http-cve
      ;;
    all)
      set -- crowdsecurity/linux crowdsecurity/sshd crowdsecurity/iptables crowdsecurity/nginx crowdsecurity/apache2 crowdsecurity/http-cve
      ;;
    *)
      set -- crowdsecurity/linux crowdsecurity/sshd
      ;;
  esac
  for col in "$@"; do
    echo "Install collection if available: ${col}"
    crowdsec_cscli collections install "${col}" || true
  done
  echo "CrowdSec Hub upgrade..."
  crowdsec_cscli hub upgrade || true
  restart_crowdsec_runtime || true
  echo "Installed collections:"
  crowdsec_cscli collections list || true
}

apply_initial_protection_baseline() {
  safe_source_env
  echo "Applying initial free/local CrowdSec protection baseline..."
  protection_install_collection_group base
  echo
  echo "Free/local mode is ready. Bouncers will enforce local decisions generated by central/VPS/device log analysis."
  echo "Premium blocklists are not enabled automatically."
}

show_hub_and_rules_status() {
  local tmp
  tmp="$(mktemp)"
  {
    echo "=== Hub status ==="
    crowdsec_cscli hub list 2>&1 || true
    echo
    echo "=== Installed collections ==="
    crowdsec_cscli collections list 2>&1 || true
    echo
    echo "=== Installed scenarios ==="
    crowdsec_cscli scenarios list 2>&1 || true
    echo
    echo "=== Installed parsers ==="
    crowdsec_cscli parsers list 2>&1 || true
    echo
    echo "=== Metrics ==="
    crowdsec_cscli metrics 2>&1 || true
  } >"${tmp}"
  show_file "$(T "Правила и Hub CrowdSec" "CrowdSec rules and Hub")" "${tmp}"
  rm -f "${tmp}"
}

show_active_decisions() {
  local tmp
  tmp="$(mktemp)"
  {
    echo "=== Active decisions ==="
    crowdsec_cscli decisions list -a 2>&1 || crowdsec_cscli decisions list 2>&1 || true
  } >"${tmp}"
  show_file "$(T "Активные decisions" "Active decisions")" "${tmp}"
  rm -f "${tmp}"
}

add_manual_decision() {
  local target duration reason dtype
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    target="$(whiptail --title " $(T "Manual ban decision" "Manual ban decision") " --inputbox "$(T "IP или CIDR/range для ручной блокировки.\n\nНапример: 1.2.3.4 или 1.2.3.0/24" "IP or CIDR/range to manually block.\n\nExample: 1.2.3.4 or 1.2.3.0/24")" 12 88 "" 3>&1 1>&2 2>&3)" || return 0
    duration="$(whiptail --title " $(T "Длительность" "Duration") " --inputbox "$(T "Длительность decision. Например: 4h, 24h, 168h." "Decision duration. Example: 4h, 24h, 168h.")" 10 80 "24h" 3>&1 1>&2 2>&3)" || return 0
    reason="$(whiptail --title " $(T "Причина" "Reason") " --inputbox "$(T "Причина блокировки" "Block reason")" 10 80 "manual-central-ban" 3>&1 1>&2 2>&3)" || return 0
  else
    read -rp "$(T "IP или CIDR/range: " "IP or CIDR/range: ")" target || return 0
    read -rp "$(T "Длительность [24h]: " "Duration [24h]: ")" duration || return 0
    duration="${duration:-24h}"
    read -rp "$(T "Причина [manual-central-ban]: " "Reason [manual-central-ban]: ")" reason || true
    reason="${reason:-manual-central-ban}"
  fi
  target="$(printf '%s' "${target:-}" | tr -cd '0-9A-Fa-f:.\/')"
  [[ -n "${target}" ]] || fail "$(T "Цель блокировки не может быть пустой." "Decision target cannot be empty.")"
  if trusted_ip_is_listed "${target}"; then
    fail "$(T "Этот IP/CIDR находится в доверенном списке скрипта. Ручной ban отменён." "This IP/CIDR is in the script trusted list. Manual ban cancelled.")"
  fi
  duration="$(printf '%s' "${duration:-24h}" | tr -cd '0-9smhdw')"
  reason="$(printf '%s' "${reason:-manual-central-ban}" | tr -cd 'A-Za-z0-9._:@/%+=,-')"
  if [[ "${target}" == */* ]]; then
    crowdsec_cscli decisions add --range "${target}" --type ban --duration "${duration}" --reason "${reason}"
  else
    crowdsec_cscli decisions add --ip "${target}" --type ban --duration "${duration}" --reason "${reason}"
  fi
  ok "$(T "Manual decision добавлен." "Manual decision added.")"
}

delete_manual_decision() {
  local target
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    target="$(whiptail --title " $(T "Удалить decision" "Delete decision") " --inputbox "$(T "IP или CIDR/range, для которого удалить decisions." "IP or CIDR/range to delete decisions for.")" 10 86 "" 3>&1 1>&2 2>&3)" || return 0
  else
    read -rp "$(T "IP или CIDR/range: " "IP or CIDR/range: ")" target || return 0
  fi
  target="$(printf '%s' "${target:-}" | tr -cd '0-9A-Fa-f:.\/')"
  [[ -n "${target}" ]] || return 0
  if [[ "${target}" == */* ]]; then
    crowdsec_cscli decisions delete --range "${target}" || true
  else
    crowdsec_cscli decisions delete --ip "${target}" || true
  fi
  ok "$(T "Decision удалён, если существовал." "Decision removed if it existed.")"
}

import_decisions_from_file() {
  local path duration reason tmp
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    path="$(whiptail --title " $(T "Импорт локального blacklist" "Import local blacklist") " --inputbox "$(T "Путь к файлу на central.\n\nФайл должен содержать один IP/CIDR в строке. Строки с # игнорируются." "Path to a file on central.\n\nThe file must contain one IP/CIDR per line. Lines with # are ignored.")" 13 92 "" 3>&1 1>&2 2>&3)" || return 0
    duration="$(whiptail --title " $(T "Длительность" "Duration") " --inputbox "$(T "Длительность imported decisions" "Imported decisions duration")" 10 80 "168h" 3>&1 1>&2 2>&3)" || return 0
  else
    read -rp "$(T "Путь к файлу: " "File path: ")" path || return 0
    read -rp "$(T "Длительность [168h]: " "Duration [168h]: ")" duration || return 0
    duration="${duration:-168h}"
  fi
  [[ -f "${path}" ]] || fail "$(T "Файл не найден." "File not found.")"
  duration="$(printf '%s' "${duration:-168h}" | tr -cd '0-9smhdw')"
  reason="manual-local-blacklist"
  import_decisions_from_file_apply() {
    local line target
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%%#*}"
      target="$(printf '%s' "${line}" | tr -cd '0-9A-Fa-f:.\/')"
      [[ -n "${target}" ]] || continue
      if trusted_ip_is_listed "${target}"; then
        echo "SKIP trusted: ${target}"
        continue
      fi
      if [[ "${target}" == */* ]]; then
        crowdsec_cscli decisions add --range "${target}" --type ban --duration "${duration}" --reason "${reason}" || true
      else
        crowdsec_cscli decisions add --ip "${target}" --type ban --duration "${duration}" --reason "${reason}" || true
      fi
    done < "${path}"
  }
  run_with_live_progress "$(T "Импорт локального blacklist" "Importing local blacklist")" import_decisions_from_file_apply
}

capi_console_status() {
  local tmp
  tmp="$(mktemp)"
  {
    echo "$(T "CAPI/Console статус. Это опционально: бесплатный local-mode работает без платных списков." "CAPI/Console status. This is optional: free local-mode works without paid lists.")"
    echo
    echo "=== cscli capi status ==="
    crowdsec_cscli capi status 2>&1 || true
    echo
    echo "=== cscli console status ==="
    crowdsec_cscli console status 2>&1 || true
    echo
    echo "$(T "Скрипт не включает платные blocklists автоматически. Если нужен CrowdSec Console/CAPI, подключай его вручную через официальный enroll/token и затем проверяй статус здесь." "The script does not enable paid blocklists automatically. If CrowdSec Console/CAPI is needed, enroll with the official token manually and then check status here.")"
  } >"${tmp}"
  show_file "$(T "CAPI/Console" "CAPI/Console")" "${tmp}"
  rm -f "${tmp}"
}

manage_collections_menu() {
  local choice
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "Collections и правила" "Collections and rules") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите набор для установки/обновления:" "Choose a set to install/update:")" 20 94 7 \
      "base" "$(T "Базовые правила: linux + sshd" "Base rules: linux + sshd")" \
      "router" "$(T "Firewall/router правила: base + iptables, если доступно" "Firewall/router rules: base + iptables if available")" \
      "web" "$(T "Web правила: nginx/apache/http-cve, если доступно" "Web rules: nginx/apache/http-cve if available")" \
      "all" "$(T "Базовые + firewall/router + web" "Base + firewall/router + web")" \
      "status" "$(T "Показать Hub, collections, scenarios, parsers" "Show Hub, collections, scenarios, parsers")" \
      3>&1 1>&2 2>&3)" || return 0
  else
    echo "1) base  2) router  3) web  4) all  5) status"
    read -rp "> " choice || return 0
    case "${choice}" in 1) choice=base;; 2) choice=router;; 3) choice=web;; 4) choice=all;; 5) choice=status;; esac
  fi
  case "${choice}" in
    base|router|web|all) run_with_live_progress "$(T "Установка/обновление collections" "Installing/updating collections")" protection_install_collection_group "${choice}" ;;
    status) show_hub_and_rules_status ;;
  esac
}

manage_decisions_menu() {
  local choice
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "Decisions и локальные blacklist" "Decisions and local blacklist") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 20 94 6 \
      "list" "$(T "Показать active decisions" "Show active decisions")" \
      "add" "$(T "Добавить manual ban decision" "Add manual ban decision")" \
      "delete" "$(T "Удалить decision по IP/CIDR" "Delete decision by IP/CIDR")" \
      "import" "$(T "Импортировать локальный blacklist из файла" "Import local blacklist from file")" \
      3>&1 1>&2 2>&3)" || return 0
  else
    echo "1) list  2) add  3) delete  4) import"
    read -rp "> " choice || return 0
    case "${choice}" in 1) choice=list;; 2) choice=add;; 3) choice=delete;; 4) choice=import;; esac
  fi
  case "${choice}" in
    list) show_active_decisions ;;
    add) add_manual_decision ;;
    delete) delete_manual_decision ;;
    import) import_decisions_from_file ;;
  esac
}

manage_trusted_ips_menu() {
  local choice
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "Доверенные IP/CIDR" "Trusted IP/CIDR") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 19 92 5 \
      "show" "$(T "Показать список" "Show list")" \
      "add" "$(T "Добавить IP/CIDR" "Add IP/CIDR")" \
      "remove" "$(T "Удалить IP/CIDR" "Remove IP/CIDR")" \
      "clean" "$(T "Удалить active decisions для доверенных IP" "Remove active decisions for trusted IPs")" \
      3>&1 1>&2 2>&3)" || return 0
  else
    echo "1) show  2) add  3) remove  4) clean"
    read -rp "> " choice || return 0
    case "${choice}" in 1) choice=show;; 2) choice=add;; 3) choice=remove;; 4) choice=clean;; esac
  fi
  case "${choice}" in
    show) show_trusted_ip_list ;;
    add) add_trusted_ip ;;
    remove) remove_trusted_ip ;;
    clean) run_with_live_progress "$(T "Очистка decisions для доверенных IP" "Cleaning decisions for trusted IPs")" remove_decisions_for_trusted_ips ;;
  esac
}

manage_protection_menu() {
  local choice
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "Защита, правила и decisions" "Protection, rules and decisions") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Central должен сам создавать decisions из логов central/VPS/device events и отдавать их bouncers. Платные blocklists не включаются автоматически." "Central should create decisions from central/VPS/device logs and serve them to bouncers. Paid blocklists are not enabled automatically.")" 22 100 8 \
      "baseline" "$(T "Применить базовую бесплатную защиту" "Apply base free protection")" \
      "collections" "$(T "Collections / rules / Hub" "Collections / rules / Hub")" \
      "decisions" "$(T "Manual decisions / local blacklists" "Manual decisions / local blacklists")" \
      "trusted" "$(T "Доверенные IP/CIDR для скрипта" "Script trusted IP/CIDR")" \
      "capi" "$(T "CAPI/Console статус (опционально)" "CAPI/Console status (optional)")" \
      "info" "$(T "Machines, bouncers, alerts, decisions" "Machines, bouncers, alerts, decisions")" \
      3>&1 1>&2 2>&3)" || return 0
  else
    echo "1) baseline  2) collections  3) decisions  4) trusted  5) capi  6) info"
    read -rp "> " choice || return 0
    case "${choice}" in 1) choice=baseline;; 2) choice=collections;; 3) choice=decisions;; 4) choice=trusted;; 5) choice=capi;; 6) choice=info;; esac
  fi
  case "${choice}" in
    baseline) run_with_live_progress "$(T "Базовая защита CrowdSec" "Base CrowdSec protection")" apply_initial_protection_baseline ;;
    collections) manage_collections_menu ;;
    decisions) manage_decisions_menu ;;
    trusted) manage_trusted_ips_menu ;;
    capi) capi_console_status ;;
    info) show_crowdsec_info ;;
  esac
}

manage_bouncer_devices_menu() {
  local choice
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "Bouncer/API устройства" "Bouncer/API devices") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 18 90 5 \
      "show" "$(T "Показать устройства и статус bouncers" "Show devices and bouncer status")" \
      "create" "$(T "Добавить bouncer/API устройство" "Add bouncer/API device")" \
      "remove" "$(T "Удалить bouncer/API устройство" "Remove bouncer/API device")" \
      "check" "$(T "Проверить bouncer Last Pull" "Check bouncer Last Pull")" \
      3>&1 1>&2 2>&3)" || return 0
  else
    echo "1) show  2) create  3) remove  4) check"
    read -rp "> " choice || return 0
    case "${choice}" in 1) choice=show;; 2) choice=create;; 3) choice=remove;; 4) choice=check;; esac
  fi
  case "${choice}" in
    show) show_bouncer_devices ;;
    create) create_openwrt_bouncer_connection ;;
    remove) remove_bouncer_device ;;
    check) check_bouncer_device_status ;;
  esac
}

manage_device_events_menu() {
  local choice
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "События от роутера/устройства" "Router/device event intake") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 19 94 5 \
      "enable" "$(T "Включить filtered syslog intake для устройства" "Enable filtered syslog intake for a device")" \
      "disable" "$(T "Отключить syslog intake для устройства" "Disable syslog intake for a device")" \
      "show" "$(T "Показать настроенные syslog intake" "Show configured syslog intake")" \
      "logs" "$(T "Показать последние события устройства" "Show latest device events")" \
      3>&1 1>&2 2>&3)" || return 0
  else
    echo "1) enable  2) disable  3) show  4) logs"
    read -rp "> " choice || return 0
    case "${choice}" in 1) choice=enable;; 2) choice=disable;; 3) choice=show;; 4) choice=logs;; esac
  fi
  case "${choice}" in
    enable) configure_device_event_intake ;;
    disable) disable_device_event_intake ;;
    show) show_remote_syslog_devices ;;
    logs) show_device_event_logs ;;
  esac
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
    public_lapi_url) configure_public_lapi_url ;;
    validate_machine) validate_machine_prompt ;;
    auto_token) regenerate_auto_token ;;
    bouncer_key) regenerate_bouncer_key ;;
    firewall) show_firewall; pause ;;
    test_lapi) test_webui_lapi; pause ;;
    restart) restart_services ;;
    update_webui) update_web_ui_only ;;
    logs) show_logs; pause ;;
    crowdsec_info) show_crowdsec_info; pause ;;
    reapply) reapply_all_settings ;;
    update_all) update_installed_stack ;;
    update_system) update_system_only ;;
    update_docker) update_docker_only ;;
    update_crowdsec) update_crowdsec_only ;;
    versions) show_versions; pause ;;
    disable_autostart) disable_login_menu ;;
    enable_autostart) enable_login_menu ;;
    repair_menu) repair_menu_installation ;;
    node_bouncer) create_named_vps_bouncer_key ;;
    device_manage) manage_bouncer_devices_menu ;;
    device_events) manage_device_events_menu ;;
    syslog_devices) show_remote_syslog_devices ;;
    language) change_language ;;
    protection_menu) manage_protection_menu ;;
    protection_baseline) run_with_live_progress "$(T "Базовая защита CrowdSec" "Base CrowdSec protection")" apply_initial_protection_baseline ;;
    protection_collections) manage_collections_menu ;;
    protection_decisions) manage_decisions_menu ;;
    protection_trusted) manage_trusted_ips_menu ;;
    protection_capi) capi_console_status ;;
    *) warn "$(T "Неизвестное действие меню." "Unknown menu action.")"; pause ;;
  esac
}


# -----------------------------------------------------------------------------
# v0.7.1 UX help, CAPI/Console enrollment and clearer menu overrides
# -----------------------------------------------------------------------------
SCRIPT_VERSION="v0.7.1-i18n-help-capi-menu"

show_help_text() {
  local title="$1" text="$2"
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]] && tui_available; then
    whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION}")" \
      --title " ${title} " --msgbox "${text}" 18 96 || true
  else
    echo
    echo "=== ${title} ==="
    printf '%s\n' "${text}"
    echo
  fi
}

action_description() {
  local key="$1"
  case "${key}" in
    status) T "Показывает состояние сервисов, открытые порты, контейнеры Docker, LAPI и основные параметры central. Используй это как первый пункт диагностики." "Shows service state, open ports, Docker containers, LAPI and main central settings. Use this as the first diagnostic step." ;;
    connect) T "Показывает сохранённые подключения VPS, machines и bouncer/API устройств. Здесь можно повторно посмотреть LAPI URL, machine name и bouncer key." "Shows saved VPS, machine and bouncer/API device connections. Use it to view LAPI URL, machine name and bouncer key again." ;;
    envfile) T "Показывает файл central.env с текущими настройками central. Там есть порты, URL, ranges и служебные ключи. Не публикуй этот вывод наружу." "Shows central.env with current central settings. It contains ports, URLs, ranges and secret keys. Do not publish this output." ;;
    crowdsec_info) T "Показывает machines, bouncers, alerts, active decisions и metrics. Это общий экран понимания: кто подключён, кто блокирует и какие решения есть." "Shows machines, bouncers, alerts, active decisions and metrics. This is the overview: who is connected, who enforces and what decisions exist." ;;
    protection_menu) T "Раздел настройки защиты central: бесплатные Hub collections, локальные rules/scenarios, ручные decisions, trusted IP и опциональное подключение к CrowdSec Console/CAPI." "Protection setup: free Hub collections, local rules/scenarios, manual decisions, trusted IPs and optional CrowdSec Console/CAPI connection." ;;
    protection_baseline) T "Ставит базовую бесплатную защиту: обновляет Hub и устанавливает linux + sshd collections. Это минимальная база, чтобы central мог создавать local decisions из своих логов." "Installs the base free protection: updates Hub and installs linux + sshd collections. This is the minimum base for central to create local decisions from its own logs." ;;
    protection_collections) T "Управление CrowdSec Hub collections. Collections ставят наборы parsers/scenarios для Linux, SSH, web-серверов и firewall/router логов." "Manage CrowdSec Hub collections. Collections install parser/scenario bundles for Linux, SSH, web servers and firewall/router logs." ;;
    protection_decisions) T "Локальные ручные блокировки. Можно добавить ban для IP/CIDR, импортировать свой blacklist из файла, удалить decision или посмотреть active decisions." "Local manual blocks. Add an IP/CIDR ban, import your own blacklist from a file, delete a decision or show active decisions." ;;
    protection_trusted) T "Локальный предохранитель скрипта: IP/CIDR из этого списка нельзя случайно забанить через ручные действия меню. Это не замена официальному allowlist CrowdSec." "Script safety list: IP/CIDR in this list cannot be accidentally banned through manual menu actions. This is not a replacement for the official CrowdSec allowlist." ;;
    protection_capi|capi_enroll) T "Подключение к CrowdSec Console/CAPI. Сюда вводится Console enrollment key из app.crowdsec.net. Это опционально: локальная бесплатная защита работает и без него." "CrowdSec Console/CAPI connection. Enter the Console enrollment key from app.crowdsec.net here. This is optional: local free protection works without it." ;;
    node_bouncer) T "Создаёт подключение VPS. Есть два режима: удалённая установка по SSH или ручная установка с ожиданием регистрации machine и последующим validate." "Creates a VPS connection. Two modes are available: remote SSH installation or manual installation with machine registration wait and validate." ;;
    validate_machine) T "Подтверждает зарегистрированные VPS machines. Это нужно для VPS/agent, но не нужно для bouncer-only устройств вроде OpenWrt firewall-bouncer." "Validates registered VPS machines. Required for VPS/agent nodes, not required for bouncer-only devices such as OpenWrt firewall-bouncer." ;;
    add_range) T "Добавляет IP/CIDR, которому разрешено обращаться к central LAPI. Обычно это IP VPS, роутера, NPM или другого доверенного источника." "Adds an IP/CIDR allowed to reach central LAPI. Usually this is a VPS, router, NPM or another trusted source IP." ;;
    remove_range) T "Удаляет IP/CIDR из allowed ranges LAPI. После удаления этот источник может потерять доступ к central LAPI." "Removes an IP/CIDR from LAPI allowed ranges. After removal that source may lose access to central LAPI." ;;
    replace_ranges) T "Полностью заменяет список allowed ranges LAPI. Используй осторожно: можно случайно отрезать доступ VPS, роутеру или NPM." "Completely replaces the LAPI allowed ranges list. Use carefully: you can cut off VPS, router or NPM access." ;;
    device_manage) T "Управление устройствами, где установлен только bouncer/API key. Такие устройства не являются machines, не требуют validate и только забирают decisions из central." "Manage devices that only have a bouncer/API key. These devices are not machines, do not need validate and only pull decisions from central." ;;
    device_events) T "Отдельная настройка событий от роутера/устройства. Bouncer сам логи не отправляет. Если нужны события, включается filtered syslog intake на central." "Separate router/device event intake setup. A bouncer does not send logs. If events are needed, enable filtered syslog intake on central." ;;
    syslog_devices) T "Показывает устройства, для которых включён remote syslog intake: порт, режим filtered/full и файлы логов на central." "Shows devices with remote syslog intake enabled: port, filtered/full mode and log files on central." ;;
    web_addr) T "Меняет LAN IP central и порт Web UI. Это влияет на адрес CrowdSec Manager в браузере." "Changes central LAN IP and Web UI port. This affects the CrowdSec Manager browser URL." ;;
    lapi_port) T "Меняет порт central LAPI. После изменения нужно обновить настройки VPS, bouncers, NPM и пробросы портов." "Changes the central LAPI port. After changing it, update VPS, bouncers, NPM and port forwards." ;;
    public_addr) T "Задаёт внешний IP/DDNS для прямого HTTP доступа к LAPI. Используй только если VPS ходят напрямую, без HTTPS reverse proxy." "Sets public IP/DDNS for direct HTTP LAPI access. Use only if VPS connect directly without an HTTPS reverse proxy." ;;
    public_lapi_url) T "Задаёт публичный HTTPS URL LAPI через Nginx Proxy Manager. Это предпочтительно для удалённых VPS вместо прямого HTTP." "Sets the public HTTPS LAPI URL through Nginx Proxy Manager. This is preferred for remote VPS instead of direct HTTP." ;;
    auto_token) T "Перегенерирует auto-registration token для регистрации machines. Новые установки VPS со старым token больше не смогут регистрироваться." "Regenerates the auto-registration token for machines. New VPS installs using the old token will no longer register." ;;
    bouncer_key) T "Перегенерирует shared bouncer key. Индивидуальные bouncer keys устройств не меняет, но shared-key подключения потребуется обновить." "Regenerates the shared bouncer key. Individual device bouncer keys are not changed, but shared-key connections must be updated." ;;
    firewall) T "Показывает текущие правила UFW/firewall central: SSH, Web UI, LAPI и syslog intake." "Shows current central UFW/firewall rules: SSH, Web UI, LAPI and syslog intake." ;;
    test_lapi) T "Проверяет доступ CrowdSec Manager/Web UI к LAPI. Используй, если Manager показывает LAPI Offline." "Tests CrowdSec Manager/Web UI access to LAPI. Use it if Manager shows LAPI Offline." ;;
    restart) T "Перезапускает CrowdSec, Docker контейнеры и Web UI. Используй после изменений или при зависании сервисов." "Restarts CrowdSec, Docker containers and Web UI. Use after changes or if services hang." ;;
    update_webui) T "Обновляет только CrowdSec Manager/Web UI контейнер, не трогая весь сервер." "Updates only the CrowdSec Manager/Web UI container, without touching the whole server." ;;
    logs) T "Показывает логи CrowdSec и Manager. Это основной пункт для поиска причин ошибок." "Shows CrowdSec and Manager logs. This is the main place to investigate errors." ;;
    reapply) T "Повторно применяет сохранённые настройки: LAPI config, Docker, UFW и связанные параметры." "Reapplies saved settings: LAPI config, Docker, UFW and related parameters." ;;
    update_all) T "Обновляет весь стек: системные пакеты, Docker, CrowdSec и Web UI. Используй для полного обслуживания." "Updates the full stack: system packages, Docker, CrowdSec and Web UI. Use for full maintenance." ;;
    update_system) T "Обновляет пакеты Debian/Ubuntu через apt." "Updates Debian/Ubuntu packages through apt." ;;
    update_docker) T "Обновляет Docker и docker compose plugin." "Updates Docker and the docker compose plugin." ;;
    update_crowdsec) T "Обновляет CrowdSec engine и связанные пакеты из репозитория CrowdSec." "Updates CrowdSec engine and related packages from the CrowdSec repository." ;;
    versions) T "Показывает версии ОС, Docker, CrowdSec, cscli и контейнеров." "Shows OS, Docker, CrowdSec, cscli and container versions." ;;
    repair_menu) T "Переустанавливает команду crowdsec-central-menu из текущего файла скрипта." "Reinstalls the crowdsec-central-menu command from the current script file." ;;
    language) T "Меняет язык интерфейса и сохраняет выбор в central.env." "Changes interface language and saves the choice to central.env." ;;
    disable_autostart) T "Отключает автозапуск меню при входе root в shell." "Disables automatic menu start when root logs into shell." ;;
    enable_autostart) T "Включает автозапуск меню при входе root в shell." "Enables automatic menu start when root logs into shell." ;;
    *) T "Описание для этого пункта пока не задано. Действие будет выполнено без дополнительных изменений." "No description is defined for this item yet. The action will run without additional changes." ;;
  esac
}

show_action_intro() {
  local key="$1" desc
  case "${CROWDSEC_SHOW_HELP:-1}" in 0|no|NO|false|FALSE) return 0 ;; esac
  desc="$(action_description "${key}")"
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]] && tui_available; then
    whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION}")" \
      --title " $(T "Описание пункта" "Menu item description") " \
      --yes-button "$(T "Продолжить" "Continue")" --no-button "$(T "Назад" "Back")" \
      --yesno "${desc}" 14 92
    return $?
  fi
  echo
  echo "--- $(T "Описание" "Description") ---"
  printf '%s\n' "${desc}"
  echo
  if has_tty; then
    read -rp "$(T "Enter - продолжить, Ctrl+C - отмена: " "Enter - continue, Ctrl+C - cancel: ")" _ </dev/tty || return 1
  fi
  return 0
}

console_enroll_with_key() {
  local enroll_key enable_all rc
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    enroll_key="$(whiptail --title " $(T "CrowdSec Console" "CrowdSec Console") " --passwordbox "$(T "Вставь Console enrollment key из app.crowdsec.net.\n\nЭто НЕ bouncer key и НЕ auto-registration token. После enroll обычно нужно подтвердить engine в веб-консоли CrowdSec." "Paste the Console enrollment key from app.crowdsec.net.\n\nThis is NOT a bouncer key and NOT an auto-registration token. After enroll you usually need to validate the engine in the CrowdSec web console.")" 14 92 "" 3>&1 1>&2 2>&3)" || return 0
    whiptail --title " $(T "Console options" "Console options") " --yes-button "$(T "Да" "Yes")" --no-button "$(T "Нет" "No")" --yesno "$(T "После enroll включить отправку всех Console options через: cscli console enable --all?\n\nЭто опционально. Если не уверен, выбери Нет." "After enroll, enable all Console options with: cscli console enable --all?\n\nThis is optional. If unsure, choose No.")" 13 88
    rc=$?
    [[ "${rc}" -eq 0 ]] && enable_all="yes" || enable_all="no"
  else
    read -rsp "$(T "Console enrollment key: " "Console enrollment key: ")" enroll_key || return 0
    echo
    read -rp "$(T "Включить cscli console enable --all? [y/N]: " "Enable cscli console enable --all? [y/N]: ")" enable_all || true
    [[ "${enable_all:-N}" =~ ^[Yy]$ ]] && enable_all="yes" || enable_all="no"
  fi
  enroll_key="$(printf '%s' "${enroll_key:-}" | tr -cd 'A-Za-z0-9._:-')"
  [[ -n "${enroll_key}" ]] || fail "$(T "Enrollment key пустой." "Enrollment key is empty.")"
  console_enroll_apply() {
    echo "Running: cscli console enroll <hidden>"
    crowdsec_cscli console enroll "${enroll_key}"
    if [[ "${enable_all}" == "yes" ]]; then
      echo "Running: cscli console enable --all"
      crowdsec_cscli console enable --all || true
    fi
    echo
    echo "Console status:"
    crowdsec_cscli console status || true
    echo
    echo "CAPI status:"
    crowdsec_cscli capi status || true
  }
  run_with_live_progress "$(T "CrowdSec Console enroll" "CrowdSec Console enroll")" console_enroll_apply || return 1
  show_help_text "$(T "CrowdSec Console" "CrowdSec Console")" "$(T "Enroll выполнен. Если статус показывает, что engine ожидает подтверждения, открой app.crowdsec.net и подтверди этот Security Engine.\n\nЛокальная защита и bouncer-only устройства работают и без Console/CAPI. Console нужна для внешней панели, community/premium-функций и централизованного управления." "Enroll completed. If status says the engine is waiting for validation, open app.crowdsec.net and validate this Security Engine.\n\nLocal protection and bouncer-only devices work without Console/CAPI. Console is used for the external dashboard, community/premium features and centralized management.")"
}

capi_register_free() {
  capi_register_apply() {
    echo "Running: cscli capi register"
    crowdsec_cscli capi register || true
    echo
    echo "CAPI status:"
    crowdsec_cscli capi status || true
  }
  run_with_live_progress "$(T "CrowdSec CAPI register" "CrowdSec CAPI register")" capi_register_apply || true
}

configure_cti_api_key() {
  local key config_dir config_file
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    key="$(whiptail --title " $(T "CrowdSec CTI API key" "CrowdSec CTI API key") " --passwordbox "$(T "Вставь CTI API key из CrowdSec Console, если он у тебя есть.\n\nЭто отдельный ключ для CTI API. Для обычного подключения engine к Console чаще нужен enrollment key, а не CTI key." "Paste the CTI API key from CrowdSec Console, if you have one.\n\nThis is a separate key for the CTI API. To connect the engine to Console, you usually need an enrollment key, not a CTI key.")" 14 92 "" 3>&1 1>&2 2>&3)" || return 0
  else
    read -rsp "$(T "CTI API key: " "CTI API key: ")" key || return 0
    echo
  fi
  key="$(printf '%s' "${key:-}" | tr -cd 'A-Za-z0-9._:-')"
  [[ -n "${key}" ]] || return 0
  config_dir="$(get_crowdsec_config_dir)"
  config_file="${config_dir}/config.yaml"
  [[ -f "${config_file}" ]] || fail "$(T "Не найден config.yaml CrowdSec." "CrowdSec config.yaml not found.")"
  cp -a "${config_file}" "${config_file}.backup-cti-$(date +%F-%H%M%S)"
  CTI_KEY="${key}" python3 - "${config_file}" <<'INNERPY'
import os, sys, yaml
path=sys.argv[1]
with open(path, 'r', errors='replace') as f:
    cfg=yaml.safe_load(f) or {}
cti=cfg.setdefault('cti', {})
cti['key']=os.environ['CTI_KEY']
cti['enabled']=True
cti.setdefault('cache_timeout', '60m')
cti.setdefault('cache_size', 50)
with open(path, 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
INNERPY
  restart_crowdsec_runtime || true
  ok "$(T "CTI API key сохранён в config.yaml." "CTI API key saved in config.yaml.")"
}

manage_capi_console_menu() {
  local choice
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "CrowdSec Console / CAPI" "CrowdSec Console / CAPI") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --item-help --menu "$(T "Здесь вводится ключ CrowdSec Console.\n\nОбычно нужен Console enrollment key: его берут в app.crowdsec.net при добавлении Security Engine.\nCAPI register отдельный и обычно не требует ввода ключа. CTI API key нужен только для CTI API." "Enter CrowdSec Console keys here.\n\nUsually you need the Console enrollment key from app.crowdsec.net when adding a Security Engine.\nCAPI register is separate and usually does not ask for a key. CTI API key is only for CTI API.")" 23 100 6 \
      "enroll" "$(T "Ввести Console enrollment key" "Enter Console enrollment key")" "$(T "Подключает этот central engine к CrowdSec Console через cscli console enroll <key>." "Connects this central engine to CrowdSec Console using cscli console enroll <key>.")" \
      "capi" "$(T "CAPI register/status" "CAPI register/status")" "$(T "Выполняет cscli capi register и показывает статус. Не включает платные blocklists." "Runs cscli capi register and shows status. Does not enable paid blocklists.")" \
      "cti" "$(T "Ввести CTI API key" "Enter CTI API key")" "$(T "Сохраняет CTI API key в config.yaml. Это отдельный ключ, не enrollment key." "Saves CTI API key to config.yaml. This is a separate key, not an enrollment key.")" \
      "status" "$(T "Показать CAPI/Console статус" "Show CAPI/Console status")" "$(T "Показывает cscli console status и cscli capi status." "Shows cscli console status and cscli capi status.")" \
      3>&1 1>&2 2>&3)" || return 0
  else
    echo "1) enroll - Console enrollment key"
    echo "2) capi - CAPI register/status"
    echo "3) cti - CTI API key"
    echo "4) status"
    read -rp "> " choice || return 0
    case "${choice}" in 1) choice=enroll;; 2) choice=capi;; 3) choice=cti;; 4) choice=status;; esac
  fi
  case "${choice}" in
    enroll) show_action_intro capi_enroll || return 0; console_enroll_with_key ;;
    capi) capi_register_free ;;
    cti) configure_cti_api_key ;;
    status) capi_console_status ;;
  esac
}

manage_protection_menu() {
  local choice
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "Защита, правила и decisions" "Protection, rules and decisions") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --item-help --menu "$(T "Этот раздел отвечает за то, ОТКУДА central берёт decisions для всех bouncers.\n\nБесплатный режим: Hub collections + анализ своих логов + ручные local decisions.\nConsole/CAPI опциональны и не включают платные blocklists автоматически." "This section controls WHERE central gets decisions for all bouncers.\n\nFree mode: Hub collections + local log analysis + manual local decisions.\nConsole/CAPI are optional and do not enable paid blocklists automatically.")" 25 104 7 \
      "baseline" "$(T "Базовая бесплатная защита" "Base free protection")" "$(T "Ставит linux + sshd collections. Минимальная база для local decisions." "Installs linux + sshd collections. Minimum base for local decisions.")" \
      "collections" "$(T "Collections / rules / Hub" "Collections / rules / Hub")" "$(T "Установка и просмотр collections, scenarios, parsers из CrowdSec Hub." "Install and view collections, scenarios, parsers from CrowdSec Hub.")" \
      "decisions" "$(T "Manual decisions / local blacklist" "Manual decisions / local blacklist")" "$(T "Ручные bans, удаление decisions и импорт своего списка IP/CIDR." "Manual bans, delete decisions and import your own IP/CIDR list.")" \
      "trusted" "$(T "Доверенные IP/CIDR" "Trusted IP/CIDR")" "$(T "Предохранитель от случайного ручного бана своих адресов через это меню." "Safety guard against manually banning your own addresses through this menu.")" \
      "capi" "$(T "CrowdSec Console / CAPI / API key" "CrowdSec Console / CAPI / API key")" "$(T "Здесь вводится Console enrollment key или CTI API key и проверяется CAPI status." "Enter Console enrollment key or CTI API key here and check CAPI status.")" \
      "info" "$(T "Machines, bouncers, alerts, decisions" "Machines, bouncers, alerts, decisions")" "$(T "Общий статус подключений, alerts, decisions и metrics." "Overall status of connections, alerts, decisions and metrics.")" \
      3>&1 1>&2 2>&3)" || return 0
  else
    echo "1) baseline - базовая защита"
    echo "2) collections - правила Hub"
    echo "3) decisions - ручные bans/local blacklist"
    echo "4) trusted - доверенные IP"
    echo "5) capi - Console/CAPI/API key"
    echo "6) info - общий статус"
    read -rp "> " choice || return 0
    case "${choice}" in 1) choice=baseline;; 2) choice=collections;; 3) choice=decisions;; 4) choice=trusted;; 5) choice=capi;; 6) choice=info;; esac
  fi
  case "${choice}" in
    baseline) show_action_intro protection_baseline || return 0; run_with_live_progress "$(T "Базовая защита CrowdSec" "Base CrowdSec protection")" apply_initial_protection_baseline ;;
    collections) show_action_intro protection_collections || return 0; manage_collections_menu ;;
    decisions) show_action_intro protection_decisions || return 0; manage_decisions_menu ;;
    trusted) show_action_intro protection_trusted || return 0; manage_trusted_ips_menu ;;
    capi) show_action_intro protection_capi || return 0; manage_capi_console_menu ;;
    info) show_action_intro crowdsec_info || return 0; show_crowdsec_info ;;
  esac
}

run_menu_action() {
  safe_source_env
  show_action_intro "${1}" || return 0
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
    public_lapi_url) configure_public_lapi_url ;;
    validate_machine) validate_machine_prompt ;;
    auto_token) regenerate_auto_token ;;
    bouncer_key) regenerate_bouncer_key ;;
    firewall) show_firewall; pause ;;
    test_lapi) test_webui_lapi; pause ;;
    restart) restart_services ;;
    update_webui) update_web_ui_only ;;
    logs) show_logs; pause ;;
    crowdsec_info) show_crowdsec_info; pause ;;
    reapply) reapply_all_settings ;;
    update_all) update_installed_stack ;;
    update_system) update_system_only ;;
    update_docker) update_docker_only ;;
    update_crowdsec) update_crowdsec_only ;;
    versions) show_versions; pause ;;
    disable_autostart) disable_login_menu ;;
    enable_autostart) enable_login_menu ;;
    repair_menu) repair_menu_installation ;;
    node_bouncer) create_named_vps_bouncer_key ;;
    device_manage) manage_bouncer_devices_menu ;;
    device_events) manage_device_events_menu ;;
    syslog_devices) show_remote_syslog_devices ;;
    language) change_language ;;
    protection_menu) manage_protection_menu ;;
    protection_baseline) run_with_live_progress "$(T "Базовая защита CrowdSec" "Base CrowdSec protection")" apply_initial_protection_baseline ;;
    protection_collections) manage_collections_menu ;;
    protection_decisions) manage_decisions_menu ;;
    protection_trusted) manage_trusted_ips_menu ;;
    protection_capi) manage_capi_console_menu ;;
    capi_enroll) manage_capi_console_menu ;;
    *) warn "$(T "Неизвестное действие меню." "Unknown menu action.")"; pause ;;
  esac
}

menu_loop_whiptail() {
  require_root
  tui_theme
  export CROWDSEC_TUI_MODE="whiptail"
  safe_clear
  while true; do
    local category choice summary
    summary="$(tui_summary)"
    category="$(whiptail \
      --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" \
      --title "$(T " CrowdSec Central " " CrowdSec Central ")" \
      --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --item-help \
      --menu "$(T "Выберите раздел. Внизу окна показывается подсказка по выбранному пункту.\n\n${summary}" "Choose a section. A hint for the selected item is shown at the bottom.\n\n${summary}")" 26 104 9 \
      "status" "$(T "Статус и данные" "Status and data")" "$(T "Проверка состояния, подключений, токенов и общей информации." "Check state, connections, tokens and overview info.")" \
      "protection" "$(T "Защита, правила, Console/CAPI" "Protection, rules, Console/CAPI")" "$(T "Откуда central берёт decisions: rules, collections, local blacklist, Console/CAPI key." "Where central gets decisions: rules, collections, local blacklist, Console/CAPI key.")" \
      "vps" "$(T "VPS nodes / machines" "VPS nodes / machines")" "$(T "Полноценные CrowdSec agents на VPS: установка, регистрация и validate." "Full CrowdSec agents on VPS: installation, registration and validate.")" \
      "devices" "$(T "Bouncer/API устройства" "Bouncer/API devices")" "$(T "OpenWrt/роутеры/firewall-bouncer: только получение decisions и блокировки." "OpenWrt/routers/firewall-bouncer: only pull decisions and block.")" \
      "events" "$(T "События от роутера/устройства" "Router/device events")" "$(T "Отдельный filtered syslog intake, если нужно анализировать события устройства." "Separate filtered syslog intake if device events must be analyzed.")" \
      "network" "$(T "Сеть, TLS и доступ к LAPI" "Network, TLS and LAPI access")" "$(T "Порты, HTTPS через NPM, allowed ranges, tokens и firewall." "Ports, HTTPS via NPM, allowed ranges, tokens and firewall.")" \
      "service" "$(T "Обслуживание и диагностика" "Maintenance and diagnostics")" "$(T "Рестарт, обновления, логи, версии и повторное применение настроек." "Restart, updates, logs, versions and reapply settings.")" \
      "menu" "$(T "Настройки меню" "Menu settings")" "$(T "Язык, автозапуск и переустановка команды меню." "Language, autostart and menu command repair.")" \
      "exit" "$(T "Выход" "Exit")" "$(T "Закрыть меню." "Close menu.")" \
      3>&1 1>&2 2>&3)" || continue
    [[ "${category}" == "exit" ]] && exit 0
    while true; do
      case "${category}" in
        status)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION}")" --title " $(T "Статус и данные" "Status and data") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --item-help --menu "$(T "Выберите действие. Подсказка по пункту показывается внизу." "Choose an action. A hint for the item is shown at the bottom.")" 20 96 5 \
            "status" "$(T "Статус сервисов и портов" "Service and port status")" "$(action_description status)" \
            "connect" "$(T "Показать созданные подключения" "Show saved connections")" "$(action_description connect)" \
            "envfile" "$(T "Показать central.env" "Show central.env")" "$(action_description envfile)" \
            "crowdsec_info" "$(T "Machines, bouncers, alerts, decisions" "Machines, bouncers, alerts, decisions")" "$(action_description crowdsec_info)" \
            3>&1 1>&2 2>&3)" || break ;;
        protection) manage_protection_menu; break ;;
        vps)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION}")" --title " $(T "VPS nodes / machines" "VPS nodes / machines") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --item-help --menu "$(T "VPS nodes - это полноценные CrowdSec agents, которые регистрируются как machines." "VPS nodes are full CrowdSec agents that register as machines.")" 23 104 6 \
            "node_bouncer" "$(T "Создать подключение VPS" "Create VPS connection")" "$(action_description node_bouncer)" \
            "validate_machine" "$(T "Подтвердить machine VPS" "Validate VPS machine")" "$(action_description validate_machine)" \
            "connect" "$(T "Показать созданные подключения" "Show saved connections")" "$(action_description connect)" \
            "add_range" "$(T "Добавить IP/CIDR вручную" "Add IP/CIDR manually")" "$(action_description add_range)" \
            "remove_range" "$(T "Удалить IP/CIDR из LAPI" "Remove IP/CIDR from LAPI")" "$(action_description remove_range)" \
            "replace_ranges" "$(T "Заменить весь список IP/CIDR" "Replace full IP/CIDR list")" "$(action_description replace_ranges)" \
            3>&1 1>&2 2>&3)" || break ;;
        devices) manage_bouncer_devices_menu; break ;;
        events) manage_device_events_menu; break ;;
        network)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION}")" --title " $(T "Сеть, TLS и доступ к LAPI" "Network, TLS and LAPI access") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --item-help --menu "$(T "Настройки доступа к central LAPI и Web UI. Ошибка тут может отрезать VPS/bouncers от central." "Central LAPI and Web UI access settings. A mistake here can cut VPS/bouncers off from central.")" 25 104 8 \
            "web_addr" "$(T "Изменить LAN IP или порт Web UI" "Change LAN IP or Web UI port")" "$(action_description web_addr)" \
            "lapi_port" "$(T "Изменить порт LAPI" "Change LAPI port")" "$(action_description lapi_port)" \
            "public_addr" "$(T "Внешний IP/DDNS для прямого HTTP" "Public IP/DDNS for direct HTTP")" "$(action_description public_addr)" \
            "public_lapi_url" "$(T "HTTPS LAPI через Nginx Proxy Manager" "HTTPS LAPI through Nginx Proxy Manager")" "$(action_description public_lapi_url)" \
            "auto_token" "$(T "Перегенерировать auto-registration token" "Regenerate auto-registration token")" "$(action_description auto_token)" \
            "bouncer_key" "$(T "Перегенерировать shared bouncer key" "Regenerate shared bouncer key")" "$(action_description bouncer_key)" \
            "firewall" "$(T "Показать firewall/UFW" "Show firewall/UFW")" "$(action_description firewall)" \
            "test_lapi" "$(T "Проверить Web UI -> LAPI" "Test Web UI -> LAPI")" "$(action_description test_lapi)" \
            3>&1 1>&2 2>&3)" || break ;;
        service)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION}")" --title " $(T "Обслуживание и диагностика" "Maintenance and diagnostics") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --item-help --menu "$(T "Обслуживание, обновления и диагностика ошибок." "Maintenance, updates and error diagnostics.")" 26 104 10 \
            "restart" "$(T "Перезапустить сервисы" "Restart services")" "$(action_description restart)" \
            "update_webui" "$(T "Обновить CrowdSec Manager" "Update CrowdSec Manager")" "$(action_description update_webui)" \
            "logs" "$(T "Показать логи" "Show logs")" "$(action_description logs)" \
            "reapply" "$(T "Повторно применить настройки" "Reapply settings")" "$(action_description reapply)" \
            "update_all" "$(T "Обновить весь стек" "Update full stack")" "$(action_description update_all)" \
            "update_system" "$(T "Обновить Debian packages" "Update Debian packages")" "$(action_description update_system)" \
            "update_docker" "$(T "Обновить Docker" "Update Docker")" "$(action_description update_docker)" \
            "update_crowdsec" "$(T "Обновить CrowdSec" "Update CrowdSec")" "$(action_description update_crowdsec)" \
            "versions" "$(T "Показать версии" "Show versions")" "$(action_description versions)" \
            "syslog_devices" "$(T "Показать syslog intake" "Show syslog intake")" "$(action_description syslog_devices)" \
            3>&1 1>&2 2>&3)" || break ;;
        menu)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION}")" --title " $(T "Настройки меню" "Menu settings") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --item-help --menu "$(T "Настройки самого TUI-меню." "Settings of the TUI menu itself.")" 20 96 5 \
            "disable_autostart" "$(T "Отключить автозапуск меню" "Disable menu autostart")" "$(action_description disable_autostart)" \
            "enable_autostart" "$(T "Включить автозапуск меню" "Enable menu autostart")" "$(action_description enable_autostart)" \
            "repair_menu" "$(T "Обновить/переустановить команду" "Update/reinstall command")" "$(action_description repair_menu)" \
            "language" "$(T "Изменить язык интерфейса" "Change interface language")" "$(action_description language)" \
            3>&1 1>&2 2>&3)" || break ;;
      esac
      run_menu_action "${choice}"
    done
  done
}

acquire_script_lock
load_saved_language
choose_language_if_needed

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
