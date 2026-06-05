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
DEFAULT_MANAGER_IMAGE="hhftechnology/crowdsec-manager:independent"
MANAGER_IMAGE="${MANAGER_IMAGE:-${DEFAULT_MANAGER_IMAGE}}"
MANAGER_GITHUB_REPO="hhftechnology/crowdsec_manager"
MANAGER_GITHUB_TAG="${MANAGER_GITHUB_TAG:-}"
MANAGER_IMAGE_MODE="${MANAGER_IMAGE_MODE:-image}"
MANAGER_PULL_POLICY_LINE=""
SCRIPT_VERSION="v0.8.0-manager-github-release-build"
SCRIPT_RELEASE_DATE="2026-06-05"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/central.sh"
VPS_SCRIPT_RAW_URL="https://github.com/nick2ld/scripts/raw/refs/heads/main/crowdsec/vps.sh"
REQUIRED_VPS_SCRIPT_VERSION="v0.4.9-direct-machine-credentials-fix"
CROWDSEC_ALLOWLIST_FILE="${CONFIG_DIR}/crowdsec-allowlist.tsv"
CROWDSEC_LAPI_ALLOWLIST_NAME="central-script-allowlist"
# Legacy variable kept only for migration from older script versions.
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

sanitize_remote_install_log_stream() {
  # Keep UTF-8 text, remove ANSI escape sequences and control garbage from ssh/apt logs.
  python3 -c 'import re, sys
data = sys.stdin.buffer.read().decode("utf-8", "replace")
data = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", data)
data = data.replace("\r", "")
data = "".join(ch for ch in data if ch in "\n\t" or ord(ch) >= 32)
sys.stdout.write(data)'
}

run_with_live_progress() {
  local title="$1"
  shift
  local log_file rc_file rc pct tail_text start_ts elapsed
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
      local start_ts elapsed
      start_ts="$(date +%s)"
      while kill -0 "${pid}" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start_ts ))
        tail_text="$(progress_clean_tail "${log_file}")"
        # Do not loop the gauge from 96% back to the beginning. Long SSH/apt
        # operations can sit for minutes, so keep progress monotonic and show elapsed time.
        if (( pct < 92 )); then
          pct=$((pct + 2))
        else
          pct=92
        fi
        printf 'XXX
%s
%s
%s: %ss

%s
XXX
' "${pct}" "${title}" "$(T "Выполняется" "Running")" "${elapsed}" "${tail_text}"
        sleep 1
      done
      wait "${pid}"
      local inner_rc=$?
      printf '%s' "${inner_rc}" >"${rc_file}"
      if [[ "${inner_rc}" -eq 0 ]]; then
        tail_text="$(progress_clean_tail "${log_file}")"
        printf 'XXX
100
%s

%s
XXX
' "${title} завершено" "${tail_text}"
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
    if [[ "${CROWDSEC_SUPPRESS_PROGRESS_ERROR:-0}" != "1" ]]; then
      whiptail --title " Ошибка: ${title} " --textbox "${log_file}" 30 120 || true
    fi
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
    local spin='|/-\'
    local i=0
    start_ts="$(date +%s)"
    while kill -0 "${pid}" 2>/dev/null; do
      elapsed=$(( $(date +%s) - start_ts ))
      tail_text="$(tail -n 1 "${log_file}" 2>/dev/null | tr '
' ' ' | cut -c 1-100)"
      printf '
[%s] %s (%ss): %s' "${spin:i++%${#spin}:1}" "${title}" "${elapsed}" "${tail_text:-выполняется}"
      sleep 1
    done
    printf '
%*s
' 120 ''
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
  local env_lan env_web env_lapi env_public env_ranges env_token env_bouncer env_pass env_type env_public_lapi_url env_public_lapi_mode env_npm_cidr env_ui_lang env_manager_image_mode env_manager_github_tag
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
  env_manager_image_mode="$(read_env_key MANAGER_IMAGE_MODE)"
  env_manager_github_tag="$(read_env_key MANAGER_GITHUB_TAG)"

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
  MANAGER_IMAGE_MODE="${MANAGER_IMAGE_MODE:-${env_manager_image_mode:-image}}"
  MANAGER_GITHUB_TAG="${MANAGER_GITHUB_TAG:-${env_manager_github_tag:-}}"

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
  MANAGER_IMAGE_MODE="$(sanitize_plain_value "${MANAGER_IMAGE_MODE}")"
  MANAGER_GITHUB_TAG="$(sanitize_token_value "${MANAGER_GITHUB_TAG}")"
  case "${MANAGER_IMAGE_MODE}" in
    image|github_latest|github_tag) ;;
    *) MANAGER_IMAGE_MODE="image" ;;
  esac
  if [[ "${MANAGER_IMAGE_MODE}" == "image" ]]; then
    MANAGER_IMAGE="${DEFAULT_MANAGER_IMAGE}"
  elif [[ -n "${MANAGER_GITHUB_TAG:-}" ]]; then
    MANAGER_IMAGE="$(manager_local_image_name "${MANAGER_GITHUB_TAG}")"
  fi

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
  MANAGER_IMAGE_MODE="${MANAGER_IMAGE_MODE:-image}"
  MANAGER_GITHUB_TAG="${MANAGER_GITHUB_TAG:-}"

  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"

  [[ -n "${AUTO_REG_TOKEN:-}" ]] || AUTO_REG_TOKEN="$(openssl rand -hex 32)"
  [[ -n "${SHARED_BOUNCER_KEY:-}" ]] || SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"
  [[ -n "${WEBUI_PASSWORD:-}" ]] || WEBUI_PASSWORD="$(openssl rand -hex 24)"

  RAW_RANGES="${ALLOWED_RANGES:-}" ALLOWED_RANGES="$(RAW_RANGES="${ALLOWED_RANGES:-}" sanitize_ranges)"

  PUBLIC_LAPI_URL="$(sanitize_token_value "${PUBLIC_LAPI_URL}")"
  PUBLIC_LAPI_MODE="$(sanitize_plain_value "${PUBLIC_LAPI_MODE}")"
  NPM_ALLOWED_CIDR="$(printf '%s' "${NPM_ALLOWED_CIDR}" | tr -cd '0-9A-Fa-f:.\/')"
  MANAGER_IMAGE_MODE="$(sanitize_plain_value "${MANAGER_IMAGE_MODE}")"
  MANAGER_GITHUB_TAG="$(sanitize_token_value "${MANAGER_GITHUB_TAG}")"
  case "${MANAGER_IMAGE_MODE}" in
    image|github_latest|github_tag) ;;
    *) MANAGER_IMAGE_MODE="image" ;;
  esac

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
MANAGER_IMAGE_MODE=${MANAGER_IMAGE_MODE}
MANAGER_GITHUB_TAG=${MANAGER_GITHUB_TAG}
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
  # Dockerized CrowdSec Manager mode does not need CrowdSec apt repository on the host.
  # Kept as a compatibility stub so old menu actions do not accidentally install host cscli/crowdsec.
  warn "$(T "CrowdSec apt repository на хосте не нужен в режиме CrowdSec Manager Docker. Пропускаю." "CrowdSec apt repository is not needed on the host in CrowdSec Manager Docker mode. Skipping.")"
}

install_or_update_crowdsec() {
  # In this central script the active CrowdSec engine is the Docker container named "crowdsec".
  # Installing the apt package on the host creates a second, confusing CrowdSec instance, so we do not do it.
  warn "$(T "Host CrowdSec/cscli не устанавливается. Central использует Docker-контейнер crowdsec." "Host CrowdSec/cscli is not installed. Central uses the Docker container named crowdsec.")"
  install_or_update_crowdsec_manager
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
  # Legacy Simple Web UI helper.
  # In the current CrowdSec Manager Docker mode we must never use host cscli.
  safe_source_env
  [[ -n "${WEBUI_PASSWORD:-}" ]] || WEBUI_PASSWORD="$(openssl rand -hex 24)"
  save_env
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
    log "$(T "Создаю или обновляю machine account внутри Docker engine..." "Creating/updating machine account inside the Docker engine...")"
    docker exec crowdsec cscli machines add crowdsec-web-ui --password "${WEBUI_PASSWORD}" --force --file /tmp/crowdsec-web-ui-creds.yaml >/dev/null || true
    docker exec crowdsec rm -f /tmp/crowdsec-web-ui-creds.yaml >/dev/null 2>&1 || true
    (cd "${COMPOSE_DIR}" && docker compose restart crowdsec) >/dev/null 2>&1 || docker restart crowdsec >/dev/null 2>&1 || true
    ok "$(T "Machine account для веб-морды готов в Docker engine." "Machine account for Web UI is ready in the Docker engine.")"
  else
    fail "$(T "Контейнер crowdsec не запущен. Host cscli не используется в этом central-скрипте." "The crowdsec container is not running. Host cscli is not used by this central script.")"
  fi
}

create_or_update_shared_bouncer_key() {
  safe_source_env
  [[ -n "${SHARED_BOUNCER_KEY:-}" ]] || SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"
  save_env
  if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
    fail "$(T "Контейнер crowdsec не запущен. Host cscli не используется." "The crowdsec container is not running. Host cscli is not used.")"
  fi
  if docker exec crowdsec cscli bouncers list 2>/dev/null | grep -q "shared-firewall-bouncer"; then
    ok "Bouncer shared-firewall-bouncer уже существует в Docker."
    return
  fi
  log "Создаю общий bouncer key для удалённых серверов в Docker..."
  docker exec crowdsec cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null || true
  ok "Bouncer key готов."
}


shell_quote() {
  printf '%q' "${1:-}"
}

sanitize_node_name() {
  # CrowdSec machine/bouncer names are safest when kept lowercase and simple.
  # Spaces, slashes, colons and locale characters can break cscli or make Manager output confusing.
  local raw="${1:-}" cleaned
  cleaned="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  printf '%s' "${cleaned}"
}

create_named_vps_bouncer_key() {
  safe_source_env
  local mode rc
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    set +e
    mode="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" \
      --title " $(T "Добавление VPS" "Add VPS") " \
      --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags \
      --menu "$(T "Выбери способ подключения VPS:\n\n1. Автоматически по SSH - central подключится к VPS, установит и настроит CrowdSec node.\n2. Ручной режим - central создаст данные подключения, а vps.sh запускается вручную на VPS." "Choose VPS connection mode:\n\n1. Automatic over SSH - central connects to the VPS and installs/configures the CrowdSec node.\n2. Manual mode - central creates connection data and vps.sh is run manually on the VPS.")" \
      18 100 2 \
      "remote" "$(T "VPS: подключиться по SSH и установить автоматически" "VPS: connect over SSH and install automatically")" \
      "manual" "$(T "VPS: ручное добавление с ожиданием регистрации" "VPS: manual setup with registration wait")" \
      3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0
  else
    echo
    echo "$(T "Способ добавления VPS:" "VPS add mode:")"
    echo "1) $(T "Подключиться по SSH и установить автоматически" "Connect over SSH and install automatically")"
    echo "2) $(T "Ручное добавление с ожиданием регистрации" "Manual setup with registration wait")"
    read -rp "$(T "Выбор [1/2]: " "Choice [1/2]: ")" mode || return 0
    case "${mode}" in
      1|remote) mode="remote" ;;
      *) mode="manual" ;;
    esac
  fi

  case "${mode}" in
    remote) create_named_vps_remote_install ;;
    manual) create_named_vps_bouncer_key_manual ;;
    *) return 0 ;;
  esac
}
create_vps_connection_apply_common() {
  echo "Удаление старого bouncer: ${node_name}"
  if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
    fail "$(T "Контейнер crowdsec не запущен. Host cscli не используется." "The crowdsec container is not running. Host cscli is not used.")"
  fi
  echo "Удаление старой machine: ${node_name}"
  docker exec crowdsec cscli machines delete "${node_name}" || true
  echo "Создание machine credentials в Docker LAPI: ${node_name}"
  docker exec crowdsec cscli machines add "${node_name}" --password "${machine_password}" --force >/dev/null

  docker exec crowdsec cscli bouncers delete "${node_name}" || true
  echo "Регистрация нового bouncer в Docker LAPI: ${node_name}"
  docker exec crowdsec cscli bouncers add "${node_name}" --key "${bouncer_key}"

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
  # This heredoc is intentionally not quoted because selected central-side
  # values are embedded into the remote runner. Every variable that must be
  # evaluated on the remote VPS is escaped as \${...} or \$...
  cat > "${out}" <<REMOTE
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFFNEW=1
export NO_COLOR=1
export CLICOLOR=0
export TERM=dumb
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export CROWDSEC_VPS_UNATTENDED=1

mkdir -p /root/crowdsec-vps-node
chmod 700 /root/crowdsec-vps-node

cat > /root/crowdsec-vps-node/node.env <<ENV
CENTRAL_LAPI_URL=$(shell_quote "${VPS_LAPI_URL}")
AUTO_REG_TOKEN=$(shell_quote "${AUTO_REG_TOKEN}")
SHARED_BOUNCER_KEY=$(shell_quote "${bouncer_key}")
MACHINE_NAME=$(shell_quote "${node_name}")
DIRECT_MACHINE_CREDENTIALS=yes
LAPI_MACHINE_LOGIN=$(shell_quote "${node_name}")
LAPI_MACHINE_PASSWORD=$(shell_quote "${machine_password}")
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

EXPECTED_VPS_SCRIPT_VERSION=$(shell_quote "${REQUIRED_VPS_SCRIPT_VERSION}")
VPS_SCRIPT_URL=$(shell_quote "${VPS_SCRIPT_RAW_URL}")
CACHE_BUSTER="\$(date +%s)-\$\$"
rm -f /root/crowdsec-vps-node/vps.sh /root/crowdsec-vps-node/vps.sh.tmp

download_vps_script() {
  local url="\$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 \
      -H "Cache-Control: no-cache" \
      -H "Pragma: no-cache" \
      -H "Expires: 0" \
      "\${url}" -o /root/crowdsec-vps-node/vps.sh.tmp
    return \$?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget --no-cache --tries=3 --timeout=20 -O /root/crowdsec-vps-node/vps.sh.tmp "\${url}"
    return \$?
  fi
  return 127
}

if ! download_vps_script "\${VPS_SCRIPT_URL}?cache_bust=\${CACHE_BUSTER}"; then
  echo "WARN: download with cache buster failed, retrying plain URL." >&2
  download_vps_script "\${VPS_SCRIPT_URL}"
fi

if [[ ! -s /root/crowdsec-vps-node/vps.sh.tmp ]]; then
  echo "ERROR: cannot download vps.sh. curl/wget may be missing, or GitHub raw is unavailable." >&2
  exit 88
fi

mv /root/crowdsec-vps-node/vps.sh.tmp /root/crowdsec-vps-node/vps.sh
chmod 700 /root/crowdsec-vps-node/vps.sh

if ! grep -q -- '--unattended' /root/crowdsec-vps-node/vps.sh && ! grep -q 'CROWDSEC_VPS_UNATTENDED' /root/crowdsec-vps-node/vps.sh; then
  echo "ERROR: downloaded vps.sh does not support unattended mode. Update crowdsec/vps.sh in the GitHub repository first." >&2
  exit 90
fi

DOWNLOADED_VPS_SCRIPT_VERSION="\$(grep -E '^SCRIPT_VERSION=' /root/crowdsec-vps-node/vps.sh | head -n1 | cut -d= -f2- | tr -d '"\047[:space:]')"
echo "Downloaded vps.sh version: \${DOWNLOADED_VPS_SCRIPT_VERSION:-unknown}"
echo "Required vps.sh version: \${EXPECTED_VPS_SCRIPT_VERSION}"
if [[ "\${DOWNLOADED_VPS_SCRIPT_VERSION:-}" != "\${EXPECTED_VPS_SCRIPT_VERSION}" ]]; then
  echo "ERROR: downloaded vps.sh version mismatch. This usually means an old cached script was downloaded." >&2
  echo "Expected: \${EXPECTED_VPS_SCRIPT_VERSION}" >&2
  echo "Got: \${DOWNLOADED_VPS_SCRIPT_VERSION:-unknown}" >&2
  exit 91
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
  local vps_cidr runner machine_password

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

  node_name="$(sanitize_node_name "${node_name_raw:-}")"
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
  machine_password="$(openssl rand -hex 32)"

  if ! run_with_live_progress "$(T "Подготовка подключения VPS" "Preparing VPS connection")" create_vps_connection_apply_common; then
    return 1
  fi

  runner="$(mktemp)"
  build_remote_vps_installer_script "${runner}"

  if ! run_with_live_progress "$(T "Установка SSH-клиента" "Installing SSH client tools")" ensure_remote_ssh_tools; then
    rm -f "${runner}"
    return 1
  fi

  local remote_install_log_dir remote_install_log
  remote_install_log_dir="${CONFIG_DIR}/remote-install-logs"
  mkdir -p "${remote_install_log_dir}"
  chmod 700 "${remote_install_log_dir}" 2>/dev/null || true
  remote_install_log="${remote_install_log_dir}/${node_name}-$(date +%Y%m%d-%H%M%S).log"

  remote_install_apply() {
    local step_rc
    {
      echo "Remote VPS install log"
      echo "Time: $(date -Is)"
      echo "Node: ${node_name}"
      echo "SSH: ${ssh_user}@${ssh_host}:${ssh_port}"
      echo
      echo "Проверка SSH-доступа к ${ssh_user}@${ssh_host}:${ssh_port}"
      remote_ssh_base "echo ssh-ok"
      echo
      echo "Загрузка установщика на VPS"
      remote_upload_runner "${runner}"
      echo
      echo "Запуск удалённой установки VPS"
      echo "Remote install started at: $(date -Is)"
      remote_run_runner
      step_rc=$?
      echo "Remote install finished at: $(date -Is)"
      if [[ "${step_rc}" -eq 124 ]]; then
        echo "ERROR: remote installer timeout after 45 minutes" >&2
      fi
      echo
      echo "Remote installer exit code: ${step_rc}"
      return "${step_rc}"
    } 2>&1 | sanitize_remote_install_log_stream | tee -a "${remote_install_log}"
    return "${PIPESTATUS[0]}"
  }

  if ! CROWDSEC_SUPPRESS_PROGRESS_ERROR=1 run_with_live_progress "$(T "Удалённая установка VPS node" "Remote VPS node installation")" remote_install_apply; then
    local err_tmp
    err_tmp="$(mktemp)"
    {
      echo "$(T "Удалённая установка VPS завершилась ошибкой." "Remote VPS installation failed.")"
      echo
      echo "$(T "Полный лог сохранён на central:" "Full log saved on central:")"
      echo "${remote_install_log}"
      echo
      echo "$(T "Последние строки лога:" "Last log lines:")"
      echo
      tail -n 160 "${remote_install_log}" 2>/dev/null || true
      echo
      echo "$(T "Подсказка:" "Hint:")"
      echo "$(T "Если ошибка на этапе регистрации machine, проверь реальный исходящий IP VPS в логе и allowed_ranges central LAPI." "If the error is at machine registration, check the VPS outgoing IP in the log and central LAPI allowed_ranges.")"
      echo "$(T "Также проверь логи контейнера central:" "Also check central container logs:") docker logs crowdsec --tail 200"
      echo "$(T "Если прогресс долго стоит на одном месте, открой лог из другого SSH-сеанса:" "If progress sits for a long time, open the log from another SSH session:") tail -f ${remote_install_log}"
    } > "${err_tmp}"
    show_file "$(T "Ошибка удалённой установки VPS" "Remote VPS installation error")" "${err_tmp}"
    rm -f "${err_tmp}" "${runner}"
    return 0
  fi
  rm -f "${runner}"

  echo "$(T "Machine credentials были заранее созданы на central, поэтому auto-registration/validate не требуется." "Machine credentials were created on central in advance, so auto-registration/validate is not required.")"
  run_with_live_progress "$(T "Проверка и перезапуск CrowdSec на VPS" "Checking and restarting CrowdSec on VPS")" remote_restart_vps_services_after_validate || true

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

  node_name="$(sanitize_node_name "${node_name:-}")"
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
  machine_password="$(openssl rand -hex 32)"

  create_named_vps_bouncer_key_apply() {
    echo "Удаление старого bouncer: ${node_name}"
    if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
      fail "$(T "Контейнер crowdsec не запущен. Host cscli не используется." "The crowdsec container is not running. Host cscli is not used.")"
    fi
    docker exec crowdsec cscli bouncers delete "${node_name}" || true
    echo "Регистрация нового bouncer в Docker LAPI: ${node_name}"
    docker exec crowdsec cscli bouncers add "${node_name}" --key "${bouncer_key}"

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
  # SSH_CONNECTION can be unset when the script is launched from a local console,
  # VM/LXC console, cron-like wrapper, sudo without an SSH session, or some web terminals.
  # With `set -u`, direct use of $SSH_CONNECTION breaks the firewall step.
  local ssh_connection_value
  ssh_connection_value="${SSH_CONNECTION:-}"
  if [[ -n "${ssh_connection_value}" ]]; then
    client_ip="${ssh_connection_value%% *}"
  else
    client_ip=""
    echo "SSH_CONNECTION не задана: текущий SSH-клиент не определён, сохраняю доступ по SSH-портам без привязки к IP."
  fi
  while IFS= read -r ssh_port; do
    [[ -n "${ssh_port}" ]] || continue
    ufw allow "${ssh_port}/tcp" comment "keep SSH port ${ssh_port}" || true
    if [[ -n "${client_ip}" ]]; then
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
    :
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
  local tmp
  tmp="$(mktemp)"
  {
    echo "$(T "Сохранённые подключения VPS:" "Saved VPS connections:")"
    echo
    if [[ -s "${CONNECTIONS_FILE}" ]]; then
      awk -F'	' '$5 != "VPS_NODE" {printf "%-20s %-24s %-18s %-42s %-22s\n", $5, $2, $3, $4, $1}' "${CONNECTIONS_FILE}"
    else
      echo "$(T "Пока нет сохранённых подключений." "No saved connections yet.")"
    fi
    echo
    echo "$(T "Пояснение:" "Note:")"
    echo "- $(T "Здесь показываются только полноценные VPS nodes/machines." "Only full VPS nodes/machines are shown here.")"
    echo "- $(T "Для VPS machine нужен validate после ручной регистрации." "A VPS machine needs validate after manual registration.")"
  } >"${tmp}"
  show_file "$(T "Подключения VPS" "VPS connections")" "${tmp}"
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
  # The central engine for this script is Dockerized CrowdSec.
  # Do not fall back to host cscli: that would manage a different CrowdSec instance.
  safe_source_env
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
    docker exec crowdsec cscli "$@"
  else
    echo "$(T "ОШИБКА: контейнер crowdsec не запущен. Host cscli намеренно не используется, чтобы не управлять другим CrowdSec instance." "ERROR: the crowdsec container is not running. Host cscli is intentionally not used to avoid managing another CrowdSec instance.")" >&2
    return 1
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
  if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
    fail "$(T "Контейнер crowdsec не запущен. Host cscli не используется." "The crowdsec container is not running. Host cscli is not used.")"
  fi
  docker exec crowdsec cscli bouncers delete shared-firewall-bouncer >/dev/null 2>&1 || true
  docker exec crowdsec cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null || true

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
repair_menu_installation() { print_header; update_menu_from_github; ok "$(T "Скрипт обновлён из GitHub и установлен в систему: sudo crowdsec-central-menu" "Script updated from GitHub and installed into the system: sudo crowdsec-central-menu")"; pause; }

show_versions() {
  local tmp
  tmp="$(mktemp)"
  {
    print_header
    safe_source_env
    echo "Debian/Ubuntu:"
    [[ -f /etc/os-release ]] && grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '"' || true
    echo
    echo "Docker:"
    command -v docker >/dev/null 2>&1 && { docker --version; docker compose version; } || echo "не установлен"
    echo
    echo "CrowdSec Docker engine:"
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
      docker exec crowdsec cscli version 2>&1 || true
    else
      echo "контейнер crowdsec не запущен"
    fi
    echo
    echo "CrowdSec Manager image:"
    echo "source mode: ${MANAGER_IMAGE_MODE:-image}"
    echo "github tag:  ${MANAGER_GITHUB_TAG:-not set}"
    echo "image:       ${MANAGER_IMAGE}"
    command -v docker >/dev/null 2>&1 && docker images "${MANAGER_IMAGE}" || true
    echo
    echo "Host cscli:"
    if command -v cscli >/dev/null 2>&1; then
      echo "найден на хосте, но этим скриптом не используется"
    else
      echo "не установлен и не нужен для Dockerized central"
    fi
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


show_remote_install_logs() {
  local log_dir="${CONFIG_DIR}/remote-install-logs"
  local tmp choice log_file rc
  mkdir -p "${log_dir}"
  chmod 700 "${log_dir}" 2>/dev/null || true

  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]] && tui_available; then
    local entries=()
    while IFS= read -r log_file; do
      [[ -n "${log_file}" ]] || continue
      entries+=("${log_file}" "$(basename "${log_file}")")
    done < <(find "${log_dir}" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR<=30 {sub(/^[^ ]+ /,""); print}')
    if [[ "${#entries[@]}" -eq 0 ]]; then
      whiptail --title " $(T "Логи удалённой установки VPS" "Remote VPS install logs") " --msgbox "$(T "Логи удалённой установки VPS пока не найдены." "No remote VPS installation logs found yet.")" 8 78 || true
      return 0
    fi
    set +e
    choice="$(whiptail --title " $(T "Логи удалённой установки VPS" "Remote VPS install logs") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Открыть" "Open")" --notags --menu "$(T "Выберите лог для просмотра:" "Choose a log to view:")" 24 110 14 "${entries[@]}" 3>&1 1>&2 2>&3)"
    rc=$?
    set -e
    [[ "${rc}" -eq 0 ]] || return 0
    show_file "$(T "Лог удалённой установки VPS" "Remote VPS install log")" "${choice}"
    return 0
  fi

  tmp="$(mktemp)"
  {
    echo "$(T "Логи удалённой установки VPS:" "Remote VPS installation logs:")"
    echo
    find "${log_dir}" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -r | head -n 30 || true
    echo
    echo "$(T "Открой нужный файл через less/cat." "Open the needed file with less/cat.")"
  } >"${tmp}"
  show_file "$(T "Логи удалённой установки VPS" "Remote VPS install logs")" "${tmp}"
  rm -f "${tmp}"
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
    manager_source) configure_manager_image_source ;;
    install_stack) install_or_repair_full_stack ;;
    restart) restart_services ;;
    update_webui) update_web_ui_only ;;
    logs) show_logs; pause ;;
    remote_logs) show_remote_install_logs ;;
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
    node_bouncer) create_named_vps_bouncer_key || true ;;
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
      --menu "$(T "Выберите раздел:\n\n${summary}" "Choose a section:\n\n${summary}")" \
      24 96 7 \
      "install" "$(T "Установка и первичная настройка" "Install and initial setup")" \
      "status" "$(T "Статус и данные" "Status and data")" \
      "vps" "$(T "VPS nodes / machines" "VPS nodes / machines")" \
      "protection" "$(T "Защита, правила и decisions" "Protection, rules and decisions")" \
      "network" "$(T "Сеть, TLS и доступ к LAPI" "Network, TLS and LAPI access")" \
      "service" "$(T "Обслуживание и диагностика" "Maintenance and diagnostics")" \
      "menu" "$(T "Настройки меню" "Menu settings")" \
      "exit" "$(T "Выход" "Exit")" \
      3>&1 1>&2 2>&3)" || continue
    [[ "${category}" == "exit" ]] && exit 0

    while true; do
      case "${category}" in
        install)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "Установка и первичная настройка" "Install and initial setup") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Последовательные шаги установки и восстановления." "Sequential installation and repair steps.")" 19 96 6 \
            "manager_source" "$(T "0. Источник/версия CrowdSec Manager" "0. CrowdSec Manager source/version")" \
            "install_stack" "$(T "1. Установить/восстановить CrowdSec Manager + Dockerized CrowdSec" "1. Install/repair CrowdSec Manager + Dockerized CrowdSec")" \
            "protection_baseline" "$(T "2. Применить базовую защиту" "2. Apply base protection")" \
            "firewall" "$(T "3. Проверить firewall/UFW" "3. Check firewall/UFW")" \
            "connect" "$(T "4. Показать адреса и данные подключения" "4. Show addresses and connection data")" \
            3>&1 1>&2 2>&3)" || break
          ;;
        status)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "Статус и данные" "Status and data") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 18 88 5 \
            "status" "$(T "Статус сервисов и портов" "Service and port status")" \
            "connect" "$(T "Показать созданные подключения VPS" "Show saved VPS connections")" \
            "envfile" "$(T "Показать central.env" "Show central.env")" \
            "crowdsec_info" "$(T "Machines, bouncers, alerts, decisions" "Machines, bouncers, alerts, decisions")" \
            3>&1 1>&2 2>&3)" || break
          ;;
        vps)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "VPS nodes / machines" "VPS nodes / machines") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Работа только с полноценными VPS nodes/machines." "Only full VPS nodes/machines are managed here.")" 20 96 6 \
            "node_bouncer" "$(T "Создать подключение VPS: SSH или ручное" "Create VPS connection: SSH or manual")" \
            "validate_machine" "$(T "Подтвердить machine VPS" "Validate VPS machine")" \
            "connect" "$(T "Показать созданные подключения VPS" "Show saved VPS connections")" \
            "add_range" "$(T "Добавить IP/CIDR вручную" "Add IP/CIDR manually")" \
            "remove_range" "$(T "Удалить IP/CIDR из LAPI" "Remove IP/CIDR from LAPI")" \
            "replace_ranges" "$(T "Заменить весь список IP/CIDR" "Replace the full IP/CIDR list")" \
            3>&1 1>&2 2>&3)" || break
          ;;
        protection)
          manage_protection_menu
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
            "test_lapi" "$(T "Проверить доступ Manager к LAPI" "Test Manager access to LAPI")" \
            3>&1 1>&2 2>&3)" || break
          ;;
        service)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "Обслуживание и диагностика" "Maintenance and diagnostics") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 24 96 11 \
            "restart" "$(T "Перезапустить CrowdSec, Docker и Manager" "Restart CrowdSec, Docker and Manager")" \
            "update_webui" "$(T "Обновить CrowdSec Manager" "Update CrowdSec Manager")" \
            "logs" "$(T "Показать логи Manager и CrowdSec" "Show Manager and CrowdSec logs")" \
            "remote_logs" "$(T "Логи удалённой установки VPS" "Remote VPS install logs")" \
            "reapply" "$(T "Повторно применить все настройки" "Reapply all settings")" \
            "update_all" "$(T "Обновить весь Dockerized stack" "Update full Dockerized stack")" \
            "update_system" "$(T "Обновить пакеты Debian" "Update Debian packages")" \
            "update_docker" "$(T "Обновить Docker" "Update Docker")" \
            "update_crowdsec" "$(T "Обновить Dockerized CrowdSec" "Update Dockerized CrowdSec")" \
            "versions" "$(T "Показать версии ПО" "Show software versions")" \
            3>&1 1>&2 2>&3)" || break
          ;;
        menu)
          choice="$(whiptail --backtitle "$(T "Панель управления CrowdSec Central | ${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE}" "CrowdSec Central Control Panel | ${SCRIPT_VERSION} from ${SCRIPT_RELEASE_DATE}")" --title " $(T "Настройки меню" "Menu settings") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 18 82 5 \
            "disable_autostart" "$(T "Отключить автозапуск меню при входе" "Disable menu autostart on login")" \
            "enable_autostart" "$(T "Включить автозапуск меню при входе" "Enable menu autostart on login")" \
            "repair_menu" "$(T "Восстановить команду меню" "Repair menu command")" \
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
    echo "$(T "[ УСТАНОВКА ]" "[ INSTALL ]")"
    echo "  1) $(T "Установить/восстановить CrowdSec Manager + Dockerized CrowdSec" "Install/repair CrowdSec Manager + Dockerized CrowdSec")"
    echo "  2) $(T "Применить базовую защиту" "Apply base protection")"
    echo " 38) $(T "Источник/версия CrowdSec Manager" "CrowdSec Manager source/version")"
    echo
    echo "$(T "[ СТАТУС ]" "[ STATUS ]")"
    echo "  3) $(T "Показать статус" "Show status")"
    echo "  4) $(T "Показать созданные подключения VPS" "Show saved VPS connections")"
    echo "  5) $(T "Показать central.env" "Show central.env")"
    echo "  6) $(T "Machines, bouncers, alerts, decisions" "Machines, bouncers, alerts, decisions")"
    echo
    echo "$(T "[ VPS / MACHINES ]" "[ VPS / MACHINES ]")"
    echo "  7) $(T "Создать подключение VPS" "Create VPS connection")"
    echo "  8) $(T "Подтвердить machine VPS" "Validate VPS machine")"
    echo "  9) $(T "Добавить IP/CIDR вручную" "Add IP/CIDR manually")"
    echo " 10) $(T "Удалить IP/CIDR из LAPI" "Remove IP/CIDR from LAPI")"
    echo " 11) $(T "Заменить список IP/CIDR" "Replace IP/CIDR list")"
    echo
    echo "$(T "[ ЗАЩИТА, ПРАВИЛА, DECISIONS ]" "[ PROTECTION, RULES, DECISIONS ]")"
    echo " 12) $(T "Меню защиты" "Protection menu")"
    echo " 13) $(T "Collections / Hub / rules" "Collections / Hub / rules")"
    echo " 14) $(T "Manual decisions / local blacklist" "Manual decisions / local blacklist")"
    echo " 15) $(T "CrowdSec allowlist IP/CIDR" "CrowdSec allowlist IP/CIDR")"
    echo
    echo "$(T "[ СЕТЬ, TLS, КЛЮЧИ ]" "[ NETWORK, TLS, KEYS ]")"
    echo " 16) $(T "Изменить LAN IP или порт Web UI" "Change LAN IP or Web UI port")"
    echo " 17) $(T "Изменить порт LAPI" "Change LAPI port")"
    echo " 18) $(T "Изменить внешний IP/DDNS" "Change public IP/DDNS")"
    echo " 19) $(T "HTTPS LAPI через Nginx Proxy Manager" "HTTPS LAPI through Nginx Proxy Manager")"
    echo " 20) $(T "Перегенерировать auto-registration token" "Regenerate auto-registration token")"
    echo " 21) $(T "Перегенерировать shared bouncer key" "Regenerate shared bouncer key")"
    echo " 22) $(T "Показать firewall/UFW" "Show firewall/UFW")"
    echo " 23) $(T "Проверить Manager -> LAPI" "Test Manager -> LAPI")"
    echo
    echo "$(T "[ ОБСЛУЖИВАНИЕ ]" "[ MAINTENANCE ]")"
    echo " 24) $(T "Перезапустить CrowdSec, Docker и Manager" "Restart CrowdSec, Docker and Manager")"
    echo " 25) $(T "Обновить CrowdSec Manager" "Update CrowdSec Manager")"
    echo " 26) $(T "Показать логи Manager и CrowdSec" "Show Manager and CrowdSec logs")"
    echo " 27) $(T "Повторно применить все настройки" "Reapply all settings")"
    echo " 28) $(T "Обновить весь стек" "Update full stack")"
    echo " 29) $(T "Обновить пакеты Debian" "Update Debian packages")"
    echo " 30) $(T "Обновить Docker" "Update Docker")"
    echo " 31) $(T "Обновить Dockerized CrowdSec" "Update Dockerized CrowdSec")"
    echo " 32) $(T "Показать версии ПО" "Show software versions")"
    echo " 33) $(T "Логи удалённой установки VPS" "Remote VPS install logs")"
    echo
    echo "$(T "[ МЕНЮ ]" "[ MENU ]")"
    echo " 34) $(T "Восстановить команду меню" "Repair menu command")"
    echo " 35) $(T "Изменить язык интерфейса" "Change interface language")"
    echo " 36) $(T "Отключить автозапуск меню" "Disable menu autostart")"
    echo " 37) $(T "Включить автозапуск меню" "Enable menu autostart")"
    echo
    echo "  0) $(T "Выход" "Exit")"
    echo
    if ! read -rp "$(T "Выбери действие [0-38]: " "Choose action [0-38]: ")" choice; then
      echo
      continue
    fi
    case "${choice}" in
      1) install_or_repair_full_stack ;;
      2) run_with_live_progress "$(T "Базовая защита CrowdSec" "Base CrowdSec protection")" apply_initial_protection_baseline ;;
      3) show_status; pause ;;
      4) show_connection_info; pause ;;
      5) show_tokens_file; pause ;;
      6) show_crowdsec_info; pause ;;
      7) create_named_vps_bouncer_key ;;
      8) validate_machine_prompt ;;
      9) add_allowed_range ;;
      10) remove_allowed_range ;;
      11) replace_allowed_ranges ;;
      12) manage_protection_menu ;;
      13) manage_collections_menu ;;
      14) manage_decisions_menu ;;
      15) manage_trusted_ips_menu ;;
      16) change_lan_ip_or_web_port ;;
      17) change_lapi_port ;;
      18) change_public_addr ;;
      19) configure_public_lapi_url ;;
      20) regenerate_auto_token ;;
      21) regenerate_bouncer_key ;;
      22) show_firewall; pause ;;
      23) test_webui_lapi; pause ;;
      24) restart_services ;;
      25) update_web_ui_only ;;
      26) show_logs; pause ;;
      27) reapply_all_settings ;;
      28) update_installed_stack ;;
      29) update_system_only ;;
      30) update_docker_only ;;
      31) update_crowdsec_only ;;
      32) show_versions; pause ;;
      33) show_remote_install_logs ;;
      34) repair_menu_installation ;;
      35) change_language ;;
      36) disable_login_menu ;;
      37) enable_login_menu ;;
      38) configure_manager_image_source ;;
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
# Dockerized CrowdSec helper overrides
# -----------------------------------------------------------------------------

crowdsec_cscli() {
  # The central engine for this script is Dockerized CrowdSec.
  # Do not fall back to host cscli: that would manage a different CrowdSec instance.
  safe_source_env
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
    docker exec crowdsec cscli "$@"
  else
    echo "$(T "ОШИБКА: контейнер crowdsec не запущен. Host cscli намеренно не используется, чтобы не управлять другим CrowdSec instance." "ERROR: the crowdsec container is not running. Host cscli is intentionally not used to avoid managing another CrowdSec instance.")" >&2
    return 1
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

crowdsec_allowlist_data_file() {
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"
  if [[ ! -s "${CROWDSEC_ALLOWLIST_FILE}" && -s "${TRUSTED_IP_FILE:-}" ]]; then
    cp -a "${TRUSTED_IP_FILE}" "${CROWDSEC_ALLOWLIST_FILE}" 2>/dev/null || true
    chmod 600 "${CROWDSEC_ALLOWLIST_FILE}" 2>/dev/null || true
  fi
  printf '%s' "${CROWDSEC_ALLOWLIST_FILE}"
}

crowdsec_allowlist_parser_path() {
  local cfg_dir
  cfg_dir="$(get_crowdsec_config_dir)"
  mkdir -p "${cfg_dir}/parsers/s02-enrich"
  printf '%s' "${cfg_dir}/parsers/s02-enrich/nick-local-allowlist.yaml"
}

crowdsec_allowlist_is_listed() {
  local value="$1" data_file
  data_file="$(crowdsec_allowlist_data_file)"
  [[ -s "${data_file}" ]] || return 1
  awk -F'\t' -v v="${value}" '($1==v){found=1} END{exit found?0:1}' "${data_file}"
}

apply_crowdsec_allowlist() {
  local data_file parser_file allowlist_name
  data_file="$(crowdsec_allowlist_data_file)"
  parser_file="$(crowdsec_allowlist_parser_path)"
  allowlist_name="${CROWDSEC_LAPI_ALLOWLIST_NAME:-central-script-allowlist}"

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'; then
    echo "ERROR: container crowdsec is not running; host crowdsec is intentionally not used." >&2
    return 1
  fi

  # CrowdSec Manager v2.x shows the new LAPI-level allowlists, not old parser whitelist files.
  # CrowdSec 1.7 provides `cscli allowlists ...`. Use that as the primary path and keep
  # the old parser file only as a fallback for engines that do not support LAPI allowlists.
  if docker exec crowdsec cscli allowlists list >/dev/null 2>&1; then
    echo "Applying real LAPI allowlist visible in CrowdSec Manager: ${allowlist_name}"

    # Recreate the managed allowlist so removals from the script are reflected in Manager too.
    docker exec crowdsec cscli allowlists delete "${allowlist_name}" >/dev/null 2>&1 || true

    if [[ ! -s "${data_file}" ]]; then
      rm -f "${parser_file}"
      echo "CrowdSec allowlist is empty. Removed managed LAPI allowlist if it existed."
    else
      docker exec crowdsec cscli allowlists create "${allowlist_name}" \
        --description "Managed by crowdsec-central-menu" >/dev/null 2>&1 || true

      while IFS=$'\t' read -r value _ comment _; do
        [[ -n "${value:-}" ]] || continue
        value="$(printf '%s' "${value}" | tr -cd '0-9A-Fa-f:.\/')"
        [[ -n "${value}" ]] || continue
        comment="$(printf '%s' "${comment:-managed-by-central-script}" | tr -cd 'A-Za-z0-9А-Яа-яёЁ ._:@/%+=,-')"
        [[ -n "${comment}" ]] || comment="managed-by-central-script"
        echo "Add to LAPI allowlist: ${value}"
        docker exec crowdsec cscli allowlists add "${allowlist_name}" "${value}" --comment "${comment}" >/dev/null
      done < "${data_file}"

      # Remove the legacy parser to avoid having two different allowlist systems with different UI visibility.
      rm -f "${parser_file}"
      echo "LAPI allowlist applied. It should now be visible in CrowdSec Manager -> Allowlists."
      echo "Current LAPI allowlist:"
      docker exec crowdsec cscli allowlists inspect "${allowlist_name}" || true
    fi

    echo "Restarting CrowdSec runtime..."
    restart_crowdsec_runtime
    return 0
  fi

  echo "WARN: this CrowdSec engine does not support cscli allowlists. Falling back to legacy parser whitelist."
  if [[ ! -s "${data_file}" ]]; then
    rm -f "${parser_file}"
    echo "CrowdSec allowlist is empty. Removed parser: ${parser_file}"
  else
    DATA_FILE="${data_file}" PARSER_FILE="${parser_file}" python3 - <<'PY'
import os, re, yaml
data_file = os.environ["DATA_FILE"]
parser_file = os.environ["PARSER_FILE"]
ips, cidrs = [], []
with open(data_file, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        value = line.split("\t", 1)[0].strip()
        value = re.sub(r"[^0-9A-Fa-f:.\/]", "", value)
        if not value:
            continue
        if "/" in value:
            if value not in cidrs:
                cidrs.append(value)
        else:
            if value not in ips:
                ips.append(value)

doc = {
    "name": "nick/local-allowlist",
    "description": "Local CrowdSec parser whitelist managed by crowdsec-central-menu",
    "whitelist": {
        "reason": "local-crowdsec-allowlist",
    },
}
if ips:
    doc["whitelist"]["ip"] = ips
if cidrs:
    doc["whitelist"]["cidr"] = cidrs

with open(parser_file, "w") as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PY
    chmod 640 "${parser_file}" 2>/dev/null || true
    echo "Legacy CrowdSec allowlist parser written: ${parser_file}"
  fi

  echo "Testing CrowdSec configuration inside Docker engine..."
  docker exec crowdsec crowdsec -c /etc/crowdsec/config.yaml -t

  echo "Restarting CrowdSec runtime..."
  restart_crowdsec_runtime
}

show_trusted_ip_list() {
  local tmp data_file parser_file allowlist_name
  data_file="$(crowdsec_allowlist_data_file)"
  parser_file="$(crowdsec_allowlist_parser_path)"
  allowlist_name="${CROWDSEC_LAPI_ALLOWLIST_NAME:-central-script-allowlist}"
  tmp="$(mktemp)"
  {
    echo "$(T "CrowdSec allowlist IP/CIDR:" "CrowdSec allowlist IP/CIDR:")"
    echo
    if [[ -s "${data_file}" ]]; then
      awk -F'\t' 'BEGIN {printf "%-32s %-24s %s\n", "IP/CIDR", "ADDED", "COMMENT"} {printf "%-32s %-24s %s\n", $1, $2, $3}' "${data_file}"
    else
      echo "$(T "Список пуст." "The list is empty.")"
    fi
    echo
    echo "$(T "Это реальная LAPI allowlist CrowdSec, которую должен видеть CrowdSec Manager." "This is a real CrowdSec LAPI allowlist that CrowdSec Manager should display.")"
    echo "LAPI allowlist name: ${allowlist_name}"
    echo
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec' && docker exec crowdsec cscli allowlists list >/dev/null 2>&1; then
      echo "=== cscli allowlists list ==="
      docker exec crowdsec cscli allowlists list 2>&1 || true
      echo
      echo "=== cscli allowlists inspect ${allowlist_name} ==="
      docker exec crowdsec cscli allowlists inspect "${allowlist_name}" 2>&1 || true
    else
      echo "This CrowdSec engine does not expose cscli allowlists; legacy parser fallback is used."
      echo "Parser path:"
      echo "  ${parser_file}"
      if [[ -f "${parser_file}" ]]; then
        echo
        cat "${parser_file}"
      fi
    fi
  } >"${tmp}"
  show_file "$(T "CrowdSec allowlist" "CrowdSec allowlist")" "${tmp}"
  rm -f "${tmp}"
}

add_trusted_ip() {
  local value comment tmp data_file
  data_file="$(crowdsec_allowlist_data_file)"
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    value="$(whiptail --title " $(T "CrowdSec allowlist" "CrowdSec allowlist") " --inputbox "$(T "IP или CIDR, который нужно добавить в allowlist CrowdSec.\n\nНапример: 192.168.1.1 или 192.168.1.0/24" "IP or CIDR to add to the CrowdSec allowlist.\n\nExample: 192.168.1.1 or 192.168.1.0/24")" 12 86 "" 3>&1 1>&2 2>&3)" || return 0
    comment="$(whiptail --title " $(T "Комментарий" "Comment") " --inputbox "$(T "Комментарий, например: vps, npm, home-vpn" "Comment, for example: vps, npm, home-vpn")" 10 86 "" 3>&1 1>&2 2>&3)" || return 0
  else
    read -rp "$(T "IP/CIDR для CrowdSec allowlist: " "IP/CIDR for CrowdSec allowlist: ")" value || return 0
    read -rp "$(T "Комментарий: " "Comment: ")" comment || true
  fi
  value="$(printf '%s' "${value:-}" | tr -cd '0-9A-Fa-f:.\/')"
  [[ -n "${value}" ]] || fail "$(T "IP/CIDR не может быть пустым." "IP/CIDR cannot be empty.")"
  comment="$(printf '%s' "${comment:-}" | tr -cd 'A-Za-z0-9А-Яа-яёЁ ._:@/%+=,-')"
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"
  touch "${data_file}"
  chmod 600 "${data_file}"
  tmp="$(mktemp)"
  awk -F'\t' -v v="${value}" '($1!=v)' "${data_file}" >"${tmp}" || true
  mv "${tmp}" "${data_file}"
  printf '%s\t%s\t%s\n' "${value}" "$(date -Is)" "${comment}" >>"${data_file}"
  run_with_live_progress "$(T "Применение CrowdSec allowlist" "Applying CrowdSec allowlist")" apply_crowdsec_allowlist || true
}

remove_trusted_ip() {
  local lines=() line choice tmp i value data_file
  data_file="$(crowdsec_allowlist_data_file)"
  [[ -s "${data_file}" ]] || { warn "$(T "CrowdSec allowlist пуст." "CrowdSec allowlist is empty.")"; pause; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] && lines+=("${line}")
  done < "${data_file}"
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    local args=()
    for i in "${!lines[@]}"; do
      args+=("$((i+1))" "$(printf '%s' "${lines[$i]}" | cut -f1,3 | tr '\t' ' ')")
    done
    choice="$(whiptail --title " $(T "Удалить из CrowdSec allowlist" "Remove from CrowdSec allowlist") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Удалить" "Remove")" --notags --menu "$(T "Выберите запись:" "Choose an entry:")" 18 92 10 "${args[@]}" 3>&1 1>&2 2>&3)" || return 0
  else
    for i in "${!lines[@]}"; do echo "$((i+1))) ${lines[$i]}"; done
    read -rp "$(T "Номер: " "Number: ")" choice || return 0
  fi
  [[ "${choice}" =~ ^[0-9]+$ ]] || return 0
  ((choice >= 1 && choice <= ${#lines[@]})) || return 0
  value="$(printf '%s' "${lines[$((choice-1))]}" | cut -f1)"
  tmp="$(mktemp)"
  awk -F'\t' -v v="${value}" '($1!=v)' "${data_file}" >"${tmp}" || true
  mv "${tmp}" "${data_file}"
  run_with_live_progress "$(T "Применение CrowdSec allowlist" "Applying CrowdSec allowlist")" apply_crowdsec_allowlist || true
}

remove_decisions_for_trusted_ips() {
  local value data_file
  data_file="$(crowdsec_allowlist_data_file)"
  [[ -s "${data_file}" ]] || { warn "$(T "CrowdSec allowlist пуст." "CrowdSec allowlist is empty.")"; return 0; }
  while IFS=$'\t' read -r value _ _; do
    [[ -n "${value:-}" ]] || continue
    echo "Remove active decisions for allowlisted value: ${value}"
    if [[ "${value}" == */* ]]; then
      crowdsec_cscli decisions delete --range "${value}" || true
    else
      crowdsec_cscli decisions delete --ip "${value}" || true
    fi
  done < "${data_file}"
}

protection_install_collection_group() {
  local group="${1:-base}" col
  echo "CrowdSec Hub update..."
  crowdsec_cscli hub update || true
  case "${group}" in
    base)
      set -- crowdsecurity/linux crowdsecurity/sshd
      ;;
    vps)
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
  echo "Free/local mode is ready. Bouncers will enforce local decisions generated by central/VPS/node log analysis."
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
  if crowdsec_allowlist_is_listed "${target}"; then
    fail "$(T "Этот IP/CIDR находится в CrowdSec allowlist. Ручной ban отменён." "This IP/CIDR is in the CrowdSec allowlist. Manual ban cancelled.")"
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
      if crowdsec_allowlist_is_listed "${target}"; then
        echo "SKIP allowlisted: ${target}"
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
      "vps" "$(T "Firewall/vps правила: base + iptables, если доступно" "Firewall/vps rules: base + iptables if available")" \
      "web" "$(T "Web правила: nginx/apache/http-cve, если доступно" "Web rules: nginx/apache/http-cve if available")" \
      "all" "$(T "Базовые + firewall + web" "Base + firewall + web")" \
      "status" "$(T "Показать Hub, collections, scenarios, parsers" "Show Hub, collections, scenarios, parsers")" \
      3>&1 1>&2 2>&3)" || return 0
  else
    echo "1) base  2) vps  3) web  4) all  5) status"
    read -rp "> " choice || return 0
    case "${choice}" in 1) choice=base;; 2) choice=vps;; 3) choice=web;; 4) choice=all;; 5) choice=status;; esac
  fi
  case "${choice}" in
    base|vps|web|all) run_with_live_progress "$(T "Установка/обновление collections" "Installing/updating collections")" protection_install_collection_group "${choice}" ;;
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
    choice="$(whiptail --title " $(T "CrowdSec allowlist IP/CIDR" "CrowdSec allowlist IP/CIDR") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Выберите действие:" "Choose an action:")" 19 92 5 \
      "show" "$(T "Показать список" "Show list")" \
      "add" "$(T "Добавить IP/CIDR" "Add IP/CIDR")" \
      "remove" "$(T "Удалить IP/CIDR" "Remove IP/CIDR")" \
      "clean" "$(T "Удалить active decisions для CrowdSec allowlist" "Remove active decisions for allowlist")" \
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
    clean) run_with_live_progress "$(T "Удаление active decisions для CrowdSec allowlist" "Removing active decisions for allowlist")" remove_decisions_for_trusted_ips ;;
  esac
}

manage_protection_menu() {
  local choice
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "Защита, правила и decisions" "Protection, rules and decisions") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Central должен сам создавать decisions из логов central/VPS/node events и отдавать их bouncers. Платные blocklists не включаются автоматически." "Central should create decisions from central/VPS/node logs and serve them to bouncers. Paid blocklists are not enabled automatically.")" 22 100 8 \
      "baseline" "$(T "Применить базовую бесплатную защиту" "Apply base free protection")" \
      "collections" "$(T "Collections / rules / Hub" "Collections / rules / Hub")" \
      "decisions" "$(T "Manual decisions / local blacklists" "Manual decisions / local blacklists")" \
      "trusted" "$(T "CrowdSec allowlist IP/CIDR" "CrowdSec allowlist IP/CIDR")" \
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
    install_stack) install_or_repair_full_stack ;;
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
# v0.7.6 CrowdSec Manager Docker audit/fix
# -----------------------------------------------------------------------------
# Final overrides below make this script consistently manage the CrowdSec engine
# used by CrowdSec Manager: the Docker container named "crowdsec".
# Host crowdsec/cscli is intentionally not used.

SCRIPT_VERSION="v0.8.0-manager-github-release-build"

ensure_manager_paths() {
  if [[ -f "${MANAGER_COMPOSE_FILE}" ]]; then
    return 0
  fi
  if [[ -f "${COMPOSE_FILE}" ]] && grep -q 'crowdsec-manager' "${COMPOSE_FILE}" 2>/dev/null; then
    MANAGER_COMPOSE_DIR="${COMPOSE_DIR}"
    MANAGER_COMPOSE_FILE="${COMPOSE_FILE}"
    return 0
  fi
  MANAGER_COMPOSE_DIR="/opt/crowdsec-manager"
  MANAGER_COMPOSE_FILE="${MANAGER_COMPOSE_DIR}/docker-compose.yml"
}

crowdsec_container_running() {
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec'
}

manager_container_running() {
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'crowdsec-manager'
}

require_crowdsec_container() {
  if ! crowdsec_container_running; then
    echo "$(T "ОШИБКА: контейнер crowdsec не запущен. Host cscli/crowdsec намеренно не используется, чтобы не управлять другим instance." "ERROR: the crowdsec container is not running. Host cscli/crowdsec is intentionally not used to avoid managing another instance.")" >&2
    return 1
  fi
}

crowdsec_cscli() {
  require_crowdsec_container || return 1
  docker exec crowdsec cscli "$@"
}

get_crowdsec_config_dir() {
  ensure_manager_paths
  if [[ -f "${MANAGER_COMPOSE_DIR}/crowdsec-config/config.yaml" ]]; then
    printf '%s' "${MANAGER_COMPOSE_DIR}/crowdsec-config"
  else
    printf '%s' "${MANAGER_COMPOSE_DIR}/crowdsec-config"
  fi
}

restart_crowdsec_runtime() {
  ensure_manager_paths
  if [[ -f "${MANAGER_COMPOSE_FILE}" ]]; then
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)
  elif crowdsec_container_running; then
    docker restart crowdsec
  else
    echo "$(T "ОШИБКА: контейнер crowdsec не запущен. Нечего перезапускать." "ERROR: the crowdsec container is not running. Nothing to restart.")" >&2
    return 1
  fi
}

configure_crowdsec_lapi() {
  configure_docker_crowdsec_lapi
}

configure_docker_crowdsec_lapi() {
  safe_source_env
  ensure_manager_paths
  local config_file="${MANAGER_COMPOSE_DIR}/crowdsec-config/config.yaml"
  [[ -f "${config_file}" ]] || fail "$(T "Не найден config.yaml Dockerized CrowdSec:" "Dockerized CrowdSec config.yaml not found:") ${config_file}"
  [[ -n "${AUTO_REG_TOKEN:-}" ]] || { AUTO_REG_TOKEN="$(openssl rand -hex 32)"; save_env; }
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

manager_local_image_name() {
  local tag="${1:-local}"
  tag="${tag#v}"
  tag="$(printf '%s' "${tag}" | tr -cd 'A-Za-z0-9_.-')"
  [[ -n "${tag}" ]] || tag="local"
  printf 'local/crowdsec-manager:%s' "${tag}"
}

manager_release_tag_valid() {
  [[ "${1:-}" =~ ^v?[0-9]+([.][0-9]+)*([._-][A-Za-z0-9]+)*$ ]]
}

get_latest_manager_release_tag() {
  local api_url="https://api.github.com/repos/${MANAGER_GITHUB_REPO}/releases/latest"
  if command -v jq >/dev/null 2>&1; then
    curl -fsSL "${api_url}" | jq -r '.tag_name // empty'
  elif command -v python3 >/dev/null 2>&1; then
    curl -fsSL "${api_url}" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("tag_name") or "").strip())'
  else
    fail "$(T "Нужен jq или python3 для чтения latest release GitHub." "jq or python3 is required to read the latest GitHub release.")"
  fi
}

build_crowdsec_manager_release() {
  local tag="${1:-}" tarball build_dir image
  [[ -n "${tag}" ]] || fail "$(T "Не указан GitHub release/tag CrowdSec Manager." "CrowdSec Manager GitHub release/tag is not set.")"
  manager_release_tag_valid "${tag}" || fail "$(T "Некорректный GitHub tag CrowdSec Manager:" "Invalid CrowdSec Manager GitHub tag:") ${tag}"

  ensure_manager_paths
  build_dir="${MANAGER_COMPOSE_DIR}/build/crowdsec-manager-${tag}"
  tarball="${MANAGER_COMPOSE_DIR}/build/crowdsec-manager-${tag}.tar.gz"
  image="$(manager_local_image_name "${tag}")"

  mkdir -p "${MANAGER_COMPOSE_DIR}/build"
  rm -rf "${build_dir}" "${tarball}"

  echo "$(T "Скачиваю CrowdSec Manager release" "Downloading CrowdSec Manager release") ${tag}..."
  curl -fL "https://github.com/${MANAGER_GITHUB_REPO}/archive/refs/tags/${tag}.tar.gz" -o "${tarball}"
  mkdir -p "${build_dir}"
  tar -xzf "${tarball}" --strip-components=1 -C "${build_dir}"

  [[ -f "${build_dir}/Dockerfile" ]] || fail "$(T "В релизе не найден Dockerfile:" "Dockerfile was not found in the release:") ${tag}"
  echo "$(T "Собираю Docker image" "Building Docker image") ${image}..."
  docker build --pull -t "${image}" "${build_dir}"

  MANAGER_GITHUB_TAG="${tag}"
  MANAGER_IMAGE="${image}"
  MANAGER_PULL_POLICY_LINE="    pull_policy: never"
  echo "$(T "Локальный image CrowdSec Manager готов:" "Local CrowdSec Manager image is ready:") ${MANAGER_IMAGE}"
}

prepare_crowdsec_manager_image() {
  safe_source_env
  MANAGER_PULL_POLICY_LINE=""
  case "${MANAGER_IMAGE_MODE:-image}" in
    image)
      MANAGER_IMAGE="${DEFAULT_MANAGER_IMAGE}"
      ;;
    github_latest)
      local latest_tag
      echo "$(T "Получаю последний release CrowdSec Manager с GitHub..." "Reading latest CrowdSec Manager release from GitHub...")"
      latest_tag="$(get_latest_manager_release_tag)"
      [[ -n "${latest_tag}" ]] || fail "$(T "GitHub не вернул latest release для CrowdSec Manager." "GitHub did not return a latest CrowdSec Manager release.")"
      build_crowdsec_manager_release "${latest_tag}"
      ;;
    github_tag)
      [[ -n "${MANAGER_GITHUB_TAG:-}" ]] || fail "$(T "Для режима specific tag нужно указать MANAGER_GITHUB_TAG." "MANAGER_GITHUB_TAG is required for specific tag mode.")"
      build_crowdsec_manager_release "${MANAGER_GITHUB_TAG}"
      ;;
    *)
      MANAGER_IMAGE_MODE="image"
      MANAGER_IMAGE="${DEFAULT_MANAGER_IMAGE}"
      ;;
  esac
}

configure_manager_image_source() {
  safe_source_env
  local choice tag rebuild_now
  if [[ "${CROWDSEC_TUI_MODE:-}" == "whiptail" && "${CROWDSEC_PROGRESS_ACTIVE:-0}" != "1" ]]; then
    choice="$(whiptail --title " $(T "Источник CrowdSec Manager" "CrowdSec Manager source") " --cancel-button "$(T "Назад" "Back")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Текущий режим: ${MANAGER_IMAGE_MODE}\nТекущий tag: ${MANAGER_GITHUB_TAG:-не задан}\n\nDocker image быстрее и стабильнее. GitHub release собирается локально из опубликованного релиза." "Current mode: ${MANAGER_IMAGE_MODE}\nCurrent tag: ${MANAGER_GITHUB_TAG:-not set}\n\nDocker image is faster and more stable. GitHub release is built locally from a published release.")" 18 96 3 \
      "image" "$(T "Официальный Docker image independent" "Official independent Docker image")" \
      "github_latest" "$(T "Собирать последний GitHub release" "Build latest GitHub release")" \
      "github_tag" "$(T "Собирать конкретный GitHub tag" "Build specific GitHub tag")" \
      3>&1 1>&2 2>&3)" || return 0
    if [[ "${choice}" == "github_tag" ]]; then
      tag="$(whiptail --title " $(T "GitHub tag" "GitHub tag") " --inputbox "$(T "Введите release/tag, например v2.3.2:" "Enter release/tag, for example v2.3.2:")" 10 70 "${MANAGER_GITHUB_TAG:-}" 3>&1 1>&2 2>&3)" || return 0
      manager_release_tag_valid "${tag}" || { whiptail --title " $(T "Ошибка" "Error") " --msgbox "$(T "Некорректный tag." "Invalid tag.")" 8 60; return 0; }
      MANAGER_GITHUB_TAG="${tag}"
    fi
    MANAGER_IMAGE_MODE="${choice}"
    case "${MANAGER_IMAGE_MODE}" in
      image|github_latest) MANAGER_GITHUB_TAG="" ;;
    esac
    save_env
    if tui_yesno "$(T "Применить сейчас" "Apply now")" "$(T "Источник сохранён. Пересобрать/переустановить CrowdSec Manager сейчас?" "Source saved. Rebuild/reinstall CrowdSec Manager now?")"; then
      run_menu_step "$(T "Установка CrowdSec Manager" "Installing CrowdSec Manager")" install_or_update_crowdsec_manager
    fi
  else
    echo "1) $(T "Docker image independent" "Independent Docker image")"
    echo "2) $(T "Latest GitHub release" "Latest GitHub release")"
    echo "3) $(T "Specific GitHub tag" "Specific GitHub tag")"
    read -rp "> " choice || return 0
    case "${choice}" in
      1) MANAGER_IMAGE_MODE="image"; MANAGER_GITHUB_TAG="" ;;
      2) MANAGER_IMAGE_MODE="github_latest"; MANAGER_GITHUB_TAG="" ;;
      3)
        read -rp "$(T "GitHub tag: " "GitHub tag: ")" tag || return 0
        manager_release_tag_valid "${tag}" || fail "$(T "Некорректный tag." "Invalid tag.")"
        MANAGER_IMAGE_MODE="github_tag"
        MANAGER_GITHUB_TAG="${tag}"
        ;;
      *) return 0 ;;
    esac
    save_env
    read -rp "$(T "Применить сейчас? [y/N]: " "Apply now? [y/N]: ")" rebuild_now || rebuild_now="n"
    case "${rebuild_now}" in
      y|Y|yes|YES|д|Д|да|ДА) install_or_update_crowdsec_manager ;;
    esac
  fi
}

write_crowdsec_manager_compose() {
  ensure_manager_paths
  mkdir -p "${MANAGER_COMPOSE_DIR}"
  chmod 755 "${MANAGER_COMPOSE_DIR}"
  mkdir -p "${MANAGER_COMPOSE_DIR}/crowdsec-db" "${MANAGER_COMPOSE_DIR}/crowdsec-config"
  chmod 700 "${MANAGER_COMPOSE_DIR}/crowdsec-db" "${MANAGER_COMPOSE_DIR}/crowdsec-config"
  cat >"${MANAGER_COMPOSE_FILE}" <<EOF
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: unless-stopped
    environment:
      - COLLECTIONS=crowdsecurity/linux crowdsecurity/sshd
      - GID=1000
    ports:
      - "${LAPI_PORT}:8080"
    volumes:
      - "${MANAGER_COMPOSE_DIR}/crowdsec-db:/var/lib/crowdsec/data"
      - "${MANAGER_COMPOSE_DIR}/crowdsec-config:/etc/crowdsec"
      - /var/log:/var/log:ro
    networks:
      - crowdsec_net

  crowdsec-manager:
    image: ${MANAGER_IMAGE}
${MANAGER_PULL_POLICY_LINE}
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
}

install_or_update_crowdsec_manager() {
  safe_source_env
  ensure_manager_paths
  if [[ "${WEB_PORT}" == "${LAPI_PORT}" ]]; then
    fail "$(T "Ошибка конфигурации: WEB_PORT и LAPI_PORT не могут быть одинаковыми." "Configuration error: WEB_PORT and LAPI_PORT cannot be the same.")"
  fi

  echo "Preparing Dockerized CrowdSec Manager in ${MANAGER_COMPOSE_DIR}"
  backup_and_remove_apt_crowdsec || true
  docker rm -f crowdsec-web-ui >/dev/null 2>&1 || true

  prepare_crowdsec_manager_image
  write_crowdsec_manager_compose

  echo "Pulling CrowdSec image..."
  (cd "${MANAGER_COMPOSE_DIR}" && docker compose pull crowdsec)
  if [[ "${MANAGER_IMAGE_MODE:-image}" == "image" ]]; then
    echo "Pulling CrowdSec Manager image..."
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose pull crowdsec-manager)
  else
    echo "Using locally built CrowdSec Manager image: ${MANAGER_IMAGE}"
  fi

  echo "Starting CrowdSec Manager stack..."
  (cd "${MANAGER_COMPOSE_DIR}" && docker compose up -d --remove-orphans)

  echo "Waiting for CrowdSec config initialization..."
  local waited=0
  while [[ ! -f "${MANAGER_COMPOSE_DIR}/crowdsec-config/config.yaml" && "${waited}" -lt 40 ]]; do
    sleep 1
    waited=$((waited + 1))
  done
  [[ -f "${MANAGER_COMPOSE_DIR}/crowdsec-config/config.yaml" ]] || fail "$(T "Контейнер crowdsec не создал config.yaml." "The crowdsec container did not create config.yaml.")"

  echo "Applying LAPI allowed ranges and auto-registration token..."
  configure_docker_crowdsec_lapi

  echo "Restarting CrowdSec container..."
  (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec)

  echo "Waiting for CrowdSec API..."
  waited=0
  until docker exec crowdsec cscli version >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    (( waited < 60 )) || fail "$(T "CrowdSec container did not become ready." "CrowdSec container did not become ready.")"
  done

  [[ -n "${SHARED_BOUNCER_KEY:-}" ]] || { SHARED_BOUNCER_KEY="$(openssl rand -hex 32)"; save_env; }
  echo "Ensuring shared-firewall-bouncer exists in Docker engine..."
  docker exec crowdsec cscli bouncers delete shared-firewall-bouncer >/dev/null 2>&1 || true
  docker exec crowdsec cscli bouncers add shared-firewall-bouncer --key "${SHARED_BOUNCER_KEY}" >/dev/null || true

  WEB_UI_TYPE="manager"
  save_env
  echo "CrowdSec Manager ready: http://${LAN_IP}:${WEB_PORT}"
}

restart_services_cmd() {
  ensure_manager_paths
  if [[ -f "${MANAGER_COMPOSE_FILE}" ]]; then
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose up -d)
    (cd "${MANAGER_COMPOSE_DIR}" && docker compose restart crowdsec crowdsec-manager) || true
  else
    docker restart crowdsec crowdsec-manager >/dev/null 2>&1 || {
      echo "$(T "ОШИБКА: compose-файл CrowdSec Manager не найден и контейнеры не запущены." "ERROR: CrowdSec Manager compose file was not found and containers are not running.")" >&2
      return 1
    }
  fi
}

reapply_all_settings_cmd() {
  WEB_UI_TYPE="manager"
  ensure_manager_paths
  configure_docker_crowdsec_lapi
  create_or_update_shared_bouncer_key
  restart_crowdsec_runtime || true
  configure_ufw_full
  install_menu_files
}

update_crowdsec_only() {
  run_menu_step "$(T "Обновление Dockerized CrowdSec engine" "Updating Dockerized CrowdSec engine")" install_or_update_crowdsec_manager
}

update_web_ui_only() {
  run_menu_step "$(T "Обновление CrowdSec Manager" "Updating CrowdSec Manager")" install_or_update_crowdsec_manager
}

update_installed_stack() {
  run_menu_step "$(T "Обновление Docker" "Updating Docker")" install_or_update_docker
  run_menu_step "$(T "Обновление Dockerized CrowdSec + Manager" "Updating Dockerized CrowdSec + Manager")" install_or_update_crowdsec_manager
  run_menu_step "$(T "Настройка Firewall" "Configuring Firewall")" configure_ufw_full
}



# -----------------------------------------------------------------------------
# v0.7.6 first-install and CrowdSec Manager stack fixes
# -----------------------------------------------------------------------------

is_crowdsec_manager_stack_installed() {
  # Do not use the mere existence of central.env as an installation marker:
  # first language selection writes UI_LANG there before the stack is installed.
  [[ -f "${MANAGER_COMPOSE_FILE}" ]] && return 0
  if command -v docker >/dev/null 2>&1; then
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq '^(crowdsec|crowdsec-manager)$' && return 0
  fi
  return 1
}

install_or_repair_full_stack() {
  require_root
  safe_source_env
  if [[ ! -f "${ENV_FILE}" ]] || ! grep -q '^WEB_PORT=' "${ENV_FILE}" 2>/dev/null || ! grep -q '^LAPI_PORT=' "${ENV_FILE}" 2>/dev/null; then
    if [[ "${CROWDSEC_TUI_MODE:-}" =~ ^(whiptail|installer)$ ]] && tui_available; then
      ask_initial_settings_tui
    else
      ask_initial_settings
    fi
  fi

  run_menu_step "$(T "Установка базовых пакетов" "Installing base packages")" install_base
  run_menu_step "$(T "Установка/обновление Docker" "Installing/updating Docker")" install_or_update_docker
  WEB_UI_TYPE="manager"
  save_env
  run_menu_step "$(T "Установка/восстановление CrowdSec Manager + Dockerized CrowdSec" "Installing/repairing CrowdSec Manager + Dockerized CrowdSec")" install_or_update_crowdsec_manager
  run_menu_step "$(T "Применение базовой защиты CrowdSec" "Applying base CrowdSec protection")" apply_initial_protection_baseline
  run_menu_step "$(T "Настройка UFW firewall" "Configuring UFW firewall")" configure_ufw_full
  run_menu_step "$(T "Установка команды меню" "Installing menu command")" install_menu_files

  if [[ "${CROWDSEC_TUI_MODE:-}" =~ ^(whiptail|installer)$ ]] && tui_available; then
    show_install_result_tui
  else
    show_install_result
    pause
  fi
}

acquire_script_lock
load_saved_language
choose_language_if_needed

case "${1:-}" in
  --install)
    full_install
    ;;
  --menu)
    menu_loop
    ;;
  *)
    if [[ "$(basename "$0")" == "crowdsec-central-menu" ]]; then
      menu_loop
    elif is_crowdsec_manager_stack_installed; then
      menu_loop
    else
      install_or_repair_full_stack
    fi
    ;;
esac
