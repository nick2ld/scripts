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
    choice="$(whiptail --title " Language / Язык " --cancel-button "Exit" --ok-button "OK" --notags --menu "Choose interface language / Выберите язык интерфейса:" 12 70 2 \
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
    choice="$(whiptail --title "$(T "$(T "Язык интерфейса" "Interface language")" "Interface language")" --cancel-button "$(T "$(T "Назад" "Back")" "Back")" --ok-button "OK" --notags --menu "$(T "Выберите язык интерфейса:" "Choose interface language:")" 12 70 2 \
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
    whiptail --title "$(T "$(T "Готово" "Done")" "Done")" --msgbox "$(T "Язык сохранён." "Language saved.")" 8 60 || true
  else
    echo "$(T "Язык сохранён." "Language saved.")"
  fi
}


CONFIG_DIR="/root/crowdsec-vps-node"
ENV_FILE="${CONFIG_DIR}/node.env"
FAIL2BAN_BACKUP_DIR="${CONFIG_DIR}/fail2ban-backup"
SCRIPT_VERSION="v0.4-i18n-unattended"
SCRIPT_RELEASE_DATE="2026-05-22"
LOCK_FILE="/var/lock/crowdsec-vps-node.lock"
LOCK_FD=200
TMP_FILES=()

log() { echo "==> $*"; }
ok() { echo "$(T "ГОТОВО" "OK"): $*"; }
warn() { echo "$(T "ВНИМАНИЕ" "WARN"): $*"; }
fail() { echo "$(T "ОШИБКА" "ERROR"): $*" >&2; exit 1; }
pause() { echo; read -rp "$(T "Нажми Enter для продолжения..." "Press Enter to continue...")" _ || true; }

register_tmp() {
  local item="$1"
  TMP_FILES+=("${item}")
}

cleanup_tmp() {
  local item
  for item in "${TMP_FILES[@]:-}"; do
    [[ -n "${item}" ]] && rm -rf "${item}" 2>/dev/null || true
  done
}

acquire_lock() {
  mkdir -p "$(dirname "${LOCK_FILE}")"
  exec {LOCK_FD}>"${LOCK_FILE}"
  if ! flock -n "${LOCK_FD}"; then
    fail "Скрипт уже запущен в другом процессе. Заверши второй запуск или удали lock после проверки: ${LOCK_FILE}"
  fi
}

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
    fail "Интерактивная установка не работает через pipe. Запусти так: sh -c 'tmp=\"\$(mktemp -t crowdsec-vps.XXXXXX)\" && curl -fsSL \"https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/vps.sh\" -o \"\$tmp\" && if [ \"\$(id -u)\" -eq 0 ]; then bash \"\$tmp\"; else sudo bash \"\$tmp\"; fi; rc=\$?; rm -f \"\$tmp\"; exit \"\$rc\"'"
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
normalize_lapi_url() {
  CENTRAL_LAPI_URL="${CENTRAL_LAPI_URL%/}"
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

tui_secret_input() {
  local title="$1"
  local text="$2"
  local default="${3:-}"
  if [[ -n "${default}" ]]; then
    whiptail --title " ${title} " --inputbox "${text}\n\nТекущее значение уже сохранено. Можно вставить новое значение или оставить как есть." 13 86 "${default}" 3>&1 1>&2 2>&3
  else
    whiptail --title " ${title} " --inputbox "${text}" 10 78 "" 3>&1 1>&2 2>&3
  fi
}

tui_yesno() {
  local title="$1"
  local text="$2"
  whiptail --title " ${title} " --yes-button "$(T "Да" "Yes")" --no-button "$(T "Нет" "No")" --yesno "${text}" 10 78
}
strip_ansi() {
  sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g'
}
run_install_step() {
  local title="$1"
  shift
  local log_file clean_log rc_file
  log_file="$(mktemp)"
  clean_log="$(mktemp)"
  rc_file="$(mktemp)"
  if tui_available; then
    set +e
    (
      set +e
      set +E
      trap - ERR
      "$@" >"${log_file}" 2>&1 &
      local pid=$! pct=3 tail_text step_rc
      while kill -0 "${pid}" 2>/dev/null; do
        tail_text="$(tail -n 8 "${log_file}" 2>/dev/null | strip_ansi | sed 's/"/'\''/g')"
        pct=$((pct + 3)); (( pct > 95 )) && pct=15
        printf 'XXX\n%s\n%s\n\n%s\nXXX\n' "${pct}" "${title}" "${tail_text:-ожидание вывода...}"
        sleep 1
      done
      wait "${pid}"
      step_rc=$?
      printf '%s' "${step_rc}" >"${rc_file}"
      exit 0
    ) | whiptail --title " CrowdSec VPS Node " --gauge "${title}" 18 90 0
    local rc
    rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      rm -f "${log_file}" "${clean_log}" "${rc_file}"
      return 0
    fi
    strip_ansi <"${log_file}" >"${clean_log}" || cp "${log_file}" "${clean_log}"
    whiptail --title " Ошибка: ${title} " --textbox "${clean_log}" 30 110 || true
    rm -f "${log_file}" "${clean_log}" "${rc_file}"
    fail "Этап установки завершился ошибкой: ${title}"
  else
    log "${title}"
  fi
  if "$@" >"${log_file}" 2>&1; then
    rm -f "${log_file}" "${clean_log}" "${rc_file}"
    return 0
  fi
  if tui_available; then
    strip_ansi <"${log_file}" >"${clean_log}" || cp "${log_file}" "${clean_log}"
    whiptail --title " Ошибка: ${title} " --textbox "${clean_log}" 30 110 || true
  else
    strip_ansi <"${log_file}" || cat "${log_file}"
  fi
  rm -f "${log_file}" "${clean_log}" "${rc_file}"
  fail "Этап установки завершился ошибкой: ${title}"
}
on_error() {
  local exit_code="$?"
  local line_no="${1:-unknown}"
  fail "Сбой на строке ${line_no}, код выхода ${exit_code}"
}
trap cleanup_tmp EXIT
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
  local had_env="no"
  if [[ -f "${ENV_FILE}" ]]; then
    had_env="yes"
    local line key value parsed
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]] && continue
      key="${line%%=*}"
      value="${line#*=}"
      key="$(printf '%s' "${key}" | tr -cd 'A-Za-z0-9_')"
      case "${key}" in
        CENTRAL_LAPI_URL|AUTO_REG_TOKEN|SHARED_BOUNCER_KEY|MACHINE_NAME|INSTALL_FIREWALL_BOUNCER|REMOVE_FAIL2BAN|COLLECTION_SELECTION_MODE|SELECTED_COLLECTIONS|HUB_ITEM_SELECTION_MODE|SELECTED_HUB_ITEMS|FIREWALL_BOUNCER_PACKAGE|FIREWALL_BOUNCER_MODE|UI_LANG) ;;
        *) continue ;;
      esac
      parsed="${value}"
      if [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        parsed="${value:1:${#value}-2}"
      elif [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        parsed="${value:1:${#value}-2}"
        parsed="${parsed//\\\"/\"}"
        parsed="${parsed//\\\\/\\}"
      elif [[ "${value}" == *\\* ]]; then
        parsed="${parsed//\\ / }"
        parsed="${parsed//\\\\/\\}"
      fi
      printf -v "${key}" '%s' "${parsed}"
    done < "${ENV_FILE}"
  fi
  CENTRAL_LAPI_URL="${CENTRAL_LAPI_URL:-}"
  normalize_lapi_url
  AUTO_REG_TOKEN="${AUTO_REG_TOKEN:-}"
  SHARED_BOUNCER_KEY="${SHARED_BOUNCER_KEY:-}"
  MACHINE_NAME="${MACHINE_NAME:-$(hostname -f 2>/dev/null || hostname)}"
  INSTALL_FIREWALL_BOUNCER="${INSTALL_FIREWALL_BOUNCER:-yes}"
  REMOVE_FAIL2BAN="${REMOVE_FAIL2BAN:-yes}"
  COLLECTION_SELECTION_MODE="${COLLECTION_SELECTION_MODE:-manual}"
  SELECTED_COLLECTIONS="${SELECTED_COLLECTIONS:-}"
  HUB_ITEM_SELECTION_MODE="${HUB_ITEM_SELECTION_MODE:-none}"
  SELECTED_HUB_ITEMS="${SELECTED_HUB_ITEMS:-}"
  FIREWALL_BOUNCER_PACKAGE="${FIREWALL_BOUNCER_PACKAGE:-}"
  FIREWALL_BOUNCER_MODE="${FIREWALL_BOUNCER_MODE:-}"
  UI_LANG="${UI_LANG:-ru}"
  case "${UI_LANG}" in en|ru) ;; *) UI_LANG="ru" ;; esac
  if [[ "${had_env}" == "yes" ]]; then
    save_env
  fi
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
REMOVE_FAIL2BAN=$(quote_env "${REMOVE_FAIL2BAN}")
COLLECTION_SELECTION_MODE=$(quote_env "${COLLECTION_SELECTION_MODE}")
SELECTED_COLLECTIONS=$(quote_env "${SELECTED_COLLECTIONS}")
HUB_ITEM_SELECTION_MODE=$(quote_env "${HUB_ITEM_SELECTION_MODE}")
SELECTED_HUB_ITEMS=$(quote_env "${SELECTED_HUB_ITEMS}")
FIREWALL_BOUNCER_PACKAGE=$(quote_env "${FIREWALL_BOUNCER_PACKAGE}")
FIREWALL_BOUNCER_MODE=$(quote_env "${FIREWALL_BOUNCER_MODE}")
UI_LANG=$(quote_env "${UI_LANG:-ru}")
ENV
  chmod 600 "${ENV_FILE}"
}

ask_settings() {
  load_env_if_exists
  if tui_available; then
    tui_theme
    whiptail --title " CrowdSec VPS Node " --msgbox "$(T "Подключение VPS к центральному CrowdSec LAPI.\n\nДанные возьми в меню центрального сервера: sudo crowdsec-central-menu" "Connect this VPS to the central CrowdSec LAPI.\n\nGet the values from the central server menu: sudo crowdsec-central-menu")" 12 78
    CENTRAL_LAPI_URL="$(tui_input "Central LAPI" "$(T "Central LAPI URL" "Central LAPI URL")" "${CENTRAL_LAPI_URL:-http://1.2.3.4:8080}")" || exit 1
    local new_auto_token new_bouncer_key
    new_auto_token="$(tui_secret_input "Central LAPI" "$(T "AUTO_REG_TOKEN" "AUTO_REG_TOKEN")" "${AUTO_REG_TOKEN:-}")" || exit 1
    if [[ -n "${new_auto_token}" || -z "${AUTO_REG_TOKEN:-}" ]]; then
      AUTO_REG_TOKEN="${new_auto_token}"
    fi
    new_bouncer_key="$(tui_secret_input "Firewall Bouncer" "BOUNCER_KEY\n\nЛучше создать индивидуальное подключение на central:\nПодключения VPS и LAPI -> Создать подключение VPS.\nТогда имя будет видно в CrowdSec Manager." "${SHARED_BOUNCER_KEY:-}")" || exit 1
    if [[ -n "${new_bouncer_key}" || -z "${SHARED_BOUNCER_KEY:-}" ]]; then
      SHARED_BOUNCER_KEY="${new_bouncer_key}"
    fi
    MACHINE_NAME="$(tui_input "Machine" "$(T "Machine name" "Machine name")" "${MACHINE_NAME}")" || exit 1
    if tui_yesno "Firewall Bouncer" "$(T "Ставить firewall-bouncer для автоматической блокировки IP?" "Install firewall-bouncer for automatic IP blocking?")"; then
      INSTALL_FIREWALL_BOUNCER="yes"
    else
      INSTALL_FIREWALL_BOUNCER="no"
    fi
    if tui_yesno "Fail2Ban" "Если Fail2Ban найден, остановить, отключить, сделать backup и удалить его?\n\nЕсли оставить Fail2Ban вместе с CrowdSec, возможны конфликты правил блокировки."; then
      REMOVE_FAIL2BAN="yes"
    else
      REMOVE_FAIL2BAN="no"
    fi
    COLLECTION_SELECTION_MODE="$(whiptail --title " Collections " --cancel-button "$(T "Отмена" "Cancel")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Как выбрать CrowdSec collections после установки агента?" "How to select CrowdSec collections after agent installation?")" 16 86 3 \
      "manual" "$(T "Показать список из CrowdSec Hub и выбрать вручную" "Show the CrowdSec Hub list and select manually")" \
      "auto" "$(T "Поставить только базовые и похожие на найденный софт" "Install base collections and detected-service matches")" \
      "base" "$(T "Поставить только linux + sshd" "Install only linux + sshd")" \
      3>&1 1>&2 2>&3)" || exit 1
    HUB_ITEM_SELECTION_MODE="$(whiptail --title " Дополнительные Hub elements " --cancel-button "$(T "Отмена" "Cancel")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "Выбирать отдельно scenarios/parsers/appsec и прочее?\n\nОбычно достаточно collections, потому что они подтягивают связанные элементы." 18 90 2 \
      "none" "$(T "Нет, только collections" "No, collections only")" \
      "manual" "$(T "Да, показать расширенный выбор Hub elements" "Yes, show advanced Hub element selection")" \
      3>&1 1>&2 2>&3)" || exit 1
    [[ -n "${CENTRAL_LAPI_URL}" ]] || fail "$(T "Central LAPI URL не может быть пустым." "Central LAPI URL cannot be empty.")"
    [[ "${CENTRAL_LAPI_URL}" =~ ^https?://[^[:space:]]+$ ]] || fail "$(T "Central LAPI URL должен начинаться с http:// или https://" "Central LAPI URL must start with http:// or https://")"
    normalize_lapi_url
    if [[ "${CENTRAL_LAPI_URL}" =~ ^http:// ]]; then
      tui_yesno " Предупреждение " "Central LAPI указан через HTTP, токены и ключи передаются без TLS. Продолжить?" || exit 1
    fi
    [[ -n "${AUTO_REG_TOKEN}" ]] || fail "$(T "AUTO_REG_TOKEN не может быть пустым." "AUTO_REG_TOKEN cannot be empty.")"
    [[ "${AUTO_REG_TOKEN}" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "$(T "AUTO_REG_TOKEN содержит недопустимые символы." "AUTO_REG_TOKEN contains invalid characters.")"
    if [[ -n "${SHARED_BOUNCER_KEY}" ]] && [[ ! "${SHARED_BOUNCER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      fail "$(T "SHARED_BOUNCER_KEY содержит недопустимые символы." "SHARED_BOUNCER_KEY contains invalid characters.")"
    fi
    if [[ "${INSTALL_FIREWALL_BOUNCER}" == "yes" && -z "${SHARED_BOUNCER_KEY}" ]]; then
      fail "$(T "Для firewall-bouncer нужен SHARED_BOUNCER_KEY." "SHARED_BOUNCER_KEY is required for firewall-bouncer.")"
    fi
    save_env
    return
  fi
  echo
  echo "Настройка подключения VPS к центральному CrowdSec LAPI."
  echo
  echo "На центральном сервере открой:"
  echo "  sudo crowdsec-central-menu"
  echo "В меню central открой: Подключения VPS и LAPI -> Создать подключение VPS."
  echo "Мастер покажет LAPI URL, AUTO_REG_TOKEN, BOUNCER_KEY и Machine name."
  echo "IP VPS добавлять вручную в CIDR не нужно: это делает мастер central."
  echo
  prompt_default input_lapi "Central LAPI URL [${CENTRAL_LAPI_URL:-http://1.2.3.4:8080}]: " "${CENTRAL_LAPI_URL:-http://1.2.3.4:8080}"
  CENTRAL_LAPI_URL="${input_lapi:-${CENTRAL_LAPI_URL}}"
  [[ -n "${CENTRAL_LAPI_URL}" ]] || fail "$(T "Central LAPI URL не может быть пустым." "Central LAPI URL cannot be empty.")"
  [[ "${CENTRAL_LAPI_URL}" =~ ^https?://[^[:space:]]+$ ]] || fail "$(T "Central LAPI URL должен начинаться с http:// или https://" "Central LAPI URL must start with http:// or https://")"
  normalize_lapi_url
  if [[ "${CENTRAL_LAPI_URL}" =~ ^http:// ]]; then
    warn "Central LAPI указан через HTTP. Токены и ключи передаются без TLS."
    read -rp "Продолжить? [y/N]: " http_confirm
    [[ "${http_confirm:-N}" =~ ^[Yy]$ ]] || fail "Отменено пользователем."
  fi

  prompt_default input_token "AUTO_REG_TOKEN: " "${AUTO_REG_TOKEN:-}"
  AUTO_REG_TOKEN="${input_token:-${AUTO_REG_TOKEN}}"
  [[ -n "${AUTO_REG_TOKEN}" ]] || fail "$(T "AUTO_REG_TOKEN не может быть пустым." "AUTO_REG_TOKEN cannot be empty.")"
  [[ "${AUTO_REG_TOKEN}" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "$(T "AUTO_REG_TOKEN содержит недопустимые символы." "AUTO_REG_TOKEN contains invalid characters.")"

  prompt_default input_bouncer "BOUNCER_KEY из мастера подключения VPS на central: " "${SHARED_BOUNCER_KEY:-}"
  SHARED_BOUNCER_KEY="${input_bouncer:-${SHARED_BOUNCER_KEY}}"
  if [[ -n "${SHARED_BOUNCER_KEY}" ]] && [[ ! "${SHARED_BOUNCER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    fail "$(T "SHARED_BOUNCER_KEY содержит недопустимые символы." "SHARED_BOUNCER_KEY contains invalid characters.")"
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
    fail "$(T "Для firewall-bouncer нужен SHARED_BOUNCER_KEY." "SHARED_BOUNCER_KEY is required for firewall-bouncer.")"
  fi

  echo
  prompt_default input_remove_fail2ban "Если Fail2Ban найден, удалить его после backup? [Y/n]: " "Y"
  if [[ "${input_remove_fail2ban:-Y}" =~ ^[Nn]$ ]]; then
    REMOVE_FAIL2BAN="no"
  else
    REMOVE_FAIL2BAN="yes"
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
  load_env_if_exists
  if [[ "${REMOVE_FAIL2BAN:-yes}" != "yes" ]]; then
    warn "Удаление Fail2Ban отключено пользователем. Возможны конфликты с CrowdSec firewall bouncer."
    return 0
  fi
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
  local tmp_installer
  tmp_installer="$(mktemp)"
  register_tmp "${tmp_installer}"
  curl -fsSL https://install.crowdsec.net -o "${tmp_installer}"
  if [[ ! -s "${tmp_installer}" ]]; then
    fail "Скачанный установщик CrowdSec пустой."
  fi
  bash -n "${tmp_installer}"
  bash "${tmp_installer}"
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
    command -v pveversion >/dev/null 2>&1 && echo "proxmox pve pveproxy pvedaemon proxmox-logs"
    [[ -d /etc/pve ]] && echo "proxmox pve pveproxy pvedaemon proxmox-logs"
    echo
    echo "systemd:"
    systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null | awk '{print $1}' || true
    echo
    echo "paths:"
    [[ -d /var/log/pve ]] && echo "/var/log/pve proxmox pve"
    [[ -f /var/log/pveproxy/access.log ]] && echo "/var/log/pveproxy/access.log pveproxy proxmox"
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
    proxmox|proxmox-logs|pve|pveproxy|pvedaemon) grep -qiE 'proxmox|pve|pveproxy|pvedaemon|/etc/pve|/var/log/pve' <<<"${detected}" ;;
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
    selected="$(whiptail --title " CrowdSec Hub collections " --cancel-button "$(T "Назад" "Back")" --ok-button "Установить" --checklist "Выбери collections для установки.\n\nПредвыбраны базовые и похожие на найденный софт/контейнеры." 30 110 18 "${args[@]}" 3>&1 1>&2 2>&3)" || selected="${SELECTED_COLLECTIONS}"
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
    selected="$(whiptail --title " Hub: ${item_type} " --cancel-button "$(T "Назад" "Back")" --ok-button "Добавить" --checklist "Выбери ${item_type} для установки." 30 110 18 "${args[@]}" 3>&1 1>&2 2>&3)" || selected=""
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

preflight_lapi_access() {
  load_env_if_exists
  normalize_lapi_url
  local health_url="${CENTRAL_LAPI_URL}/health"
  local tmp_body http_code curl_rc
  tmp_body="$(mktemp)"
  log "Проверяю доступность central LAPI: ${health_url}"
  set +e
  http_code="$(curl -sS -m 10 -o "${tmp_body}" -w '%{http_code}' "${health_url}" 2>"${tmp_body}.err")"
  curl_rc=$?
  set -e
  if [[ "${curl_rc}" -ne 0 ]]; then
    cat "${tmp_body}.err" 2>/dev/null || true
    rm -f "${tmp_body}" "${tmp_body}.err"
    fail "Central LAPI недоступен с этой VPS. Проверь адрес ${CENTRAL_LAPI_URL}, маршрут, firewall и проброс TCP-порта LAPI."
  fi
  if [[ "${http_code}" != "200" ]]; then
    echo "HTTP ${http_code} от ${health_url}"
    cat "${tmp_body}" 2>/dev/null || true
    rm -f "${tmp_body}" "${tmp_body}.err"
    case "${http_code}" in
      401|403)
        fail "Central LAPI отвечает, но доступ запрещён. На central создай подключение VPS с внешним IP этой машины: Подключения VPS и LAPI -> Создать подключение VPS."
        ;;
      000)
        fail "Central LAPI не отвечает. Проверь адрес, порт и firewall."
        ;;
      *)
        fail "Central LAPI /health вернул неожиданный HTTP ${http_code}. Проверь состояние central CrowdSec."
        ;;
    esac
  fi
  rm -f "${tmp_body}" "${tmp_body}.err"
  ok "Central LAPI доступен."
}

register_to_central_lapi() {
  load_env_if_exists
  normalize_lapi_url
  local reg_log reg_rc
  log "Регистрирую VPS на центральном LAPI..."
  mkdir -p /etc/crowdsec
  preflight_lapi_access

  if [[ -f /etc/crowdsec/local_api_credentials.yaml ]] \
    && grep -q "url: ${CENTRAL_LAPI_URL}" /etc/crowdsec/local_api_credentials.yaml \
    && ! grep -q 'temporary' /etc/crowdsec/local_api_credentials.yaml; then
    if cscli lapi status >/tmp/crowdsec-lapi-status.log 2>&1; then
      ok "VPS уже зарегистрирован на central LAPI, повторная регистрация не нужна."
      return 0
    fi
    warn "Локальные credentials есть, но cscli lapi status не прошёл. Пробую зарегистрировать заново."
  fi

  systemctl stop crowdsec || true

  # Do not delete local_api_credentials.yaml before registration.
  # Some CrowdSec versions try to read it before writing new credentials.
  if [[ ! -f /etc/crowdsec/local_api_credentials.yaml ]]; then
    cat > /etc/crowdsec/local_api_credentials.yaml <<'YAML'
url: http://127.0.0.1:8080
login: temporary
password: temporary
YAML
  fi

  cp -a /etc/crowdsec/local_api_credentials.yaml "/etc/crowdsec/local_api_credentials.yaml.backup.before-register.$(date +%F-%H%M%S)" || true

  reg_log="$(mktemp)"
  set +e
  cscli lapi register \
    --machine "${MACHINE_NAME}" \
    --url "${CENTRAL_LAPI_URL}" \
    --token "${AUTO_REG_TOKEN}" \
    --file /etc/crowdsec/local_api_credentials.yaml >"${reg_log}" 2>&1
  reg_rc=$?
  set -e

  if [[ "${reg_rc}" -ne 0 ]]; then
    cat "${reg_log}"
    rm -f "${reg_log}"
    fail "Не удалось зарегистрировать VPS на central LAPI. Если /health доступен, чаще всего причина: неверный AUTO_REG_TOKEN, IP VPS не добавлен в allowed_ranges на central или machine с таким именем уже существует."
  fi
  cat "${reg_log}" || true
  rm -f "${reg_log}"

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
  load_env_if_exists
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

show_runtime_checks() {
  load_env_if_exists
  local tmp
  tmp="$(mktemp)"
  {
    echo "============================================================"
    echo "Проверка CrowdSec VPS node"
    echo "============================================================"
    echo
    echo "Сервисы:"
    systemctl is-active crowdsec 2>/dev/null && echo "  crowdsec: active" || echo "  crowdsec: not active"
    if [[ "${INSTALL_FIREWALL_BOUNCER:-no}" == "yes" ]]; then
      systemctl is-active crowdsec-firewall-bouncer 2>/dev/null && echo "  firewall bouncer: active" || echo "  firewall bouncer: not active"
    fi
    echo
    echo "Конфигурация:"
    crowdsec -c /etc/crowdsec/config.yaml -t 2>&1 || true
    echo
    echo "LAPI:"
    cscli lapi status 2>&1 || true
    echo
    echo "Hub: installed collections"
    cscli collections list 2>&1 || true
    echo
    echo "Hub: installed scenarios / attack scenarios"
    cscli scenarios list 2>&1 || true
    echo
    echo "Hub: installed parsers"
    cscli parsers list 2>&1 || true
    echo
    echo "Hub: installed postoverflows"
    cscli postoverflows list 2>&1 || true
    echo
    echo "Hub: appsec configs"
    cscli appsec-configs list 2>&1 || true
    echo
    echo "Hub: appsec rules"
    cscli appsec-rules list 2>&1 || true
    echo
    echo "Метрики:"
    cscli metrics 2>&1 || true
    echo
    echo "Последние алерты:"
    cscli alerts list -l 20 2>&1 || true
    echo
    echo "Важно: наличие сценария проверяется через cscli scenarios list/metrics."
    echo "Боевой триггер зависит от реальных логов конкретного сервиса и его acquisition."
  } >"${tmp}"
  if tui_available; then
    whiptail --title " Проверка VPS node " --textbox "${tmp}" 34 118 || true
  else
    cat "${tmp}"
    pause
  fi
  rm -f "${tmp}"
}

full_install() {
  local skip_settings="${1:-no}"
  if [[ "${skip_settings}" != "yes" ]]; then
    ask_settings
  else
    load_env_if_exists
  fi
  if tui_available; then
    tui_theme
    run_install_step "$(T "Устанавливаю базовые пакеты" "Installing base packages")" install_base
    run_install_step "$(T "Удаляю Fail2Ban при наличии" "Removing Fail2Ban if present")" remove_fail2ban_if_installed
    run_install_step "$(T "Подключаю репозиторий CrowdSec" "Configuring CrowdSec repository")" install_crowdsec_repo
    run_install_step "$(T "Устанавливаю CrowdSec agent" "Installing CrowdSec agent")" install_crowdsec_agent
    select_hub_collections
    select_extra_hub_items
    run_install_step "$(T "Устанавливаю collections" "Installing collections")" install_collections
    run_install_step "$(T "Устанавливаю дополнительные Hub elements" "Installing additional Hub elements")" install_extra_hub_items
    run_install_step "$(T "Настраиваю источники логов" "Configuring log sources")" configure_acquisition
    run_install_step "$(T "Регистрирую VPS на центральном LAPI" "Registering VPS with central LAPI")" register_to_central_lapi
    run_install_step "$(T "Настраиваю CrowdSec node" "Configuring CrowdSec node")" configure_agent_as_node
    run_install_step "$(T "Устанавливаю firewall bouncer" "Installing firewall bouncer")" install_firewall_bouncer
    run_install_step "$(T "Проверяю конфигурацию" "Checking configuration")" test_config
    run_install_step "$(T "Перезапускаю сервисы" "Restarting services")" restart_services
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
}

manage_existing_installation() {
  load_env_if_exists
  while true; do
    local choice
    if tui_available; then
      tui_theme
      choice="$(whiptail --title " CrowdSec VPS Node " --cancel-button "$(T "Выход" "Exit")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "$(T "Узел уже установлен. Выберите действие:" "Node is already installed. Choose an action:")" 20 92 9 \
        "status" "$(T "Показать текущую сводку" "Show current summary")" \
        "collections" "$(T "Выбрать и установить CrowdSec Hub collections" "Select and install CrowdSec Hub collections")" \
        "hub" "$(T "Выбрать и установить scenarios/parsers/appsec/context" "Select and install scenarios/parsers/appsec/context")" \
        "check" "$(T "Проверить сервисы, Hub items, метрики и алерты" "Check services, Hub items, metrics, and alerts")" \
        "restart" "$(T "Перезапустить CrowdSec и bouncer" "Restart CrowdSec and bouncer")" \
        "reinstall" "$(T "Переустановить/перенастроить узел полностью" "Reinstall/reconfigure node completely")" \
        "language" "$(T "Изменить язык интерфейса" "Change interface language")" \
        "exit" "$(T "Выход" "Exit")" \
        3>&1 1>&2 2>&3)" || return 0
    else
      safe_clear
      echo "CrowdSec VPS Node (${SCRIPT_VERSION} от ${SCRIPT_RELEASE_DATE})"
      echo "1) Показать текущую сводку"
      echo "2) Выбрать и установить CrowdSec Hub collections"
      echo "3) Выбрать и установить scenarios/parsers/appsec/context"
      echo "4) Проверить сервисы, Hub items, метрики и алерты"
      echo "5) Перезапустить CrowdSec и bouncer"
      echo "6) Переустановить/перенастроить узел полностью"
      echo "7) $(T "Изменить язык интерфейса" "Change interface language")"
      echo "0) $(T "Выход" "Exit")"
      read -rp "Выбор: " plain_choice || return 0
      case "${plain_choice}" in
        1) choice="status" ;;
        2) choice="collections" ;;
        3) choice="hub" ;;
        4) choice="check" ;;
        5) choice="restart" ;;
        6) choice="reinstall" ;;
        7) choice="language" ;;
        0) choice="exit" ;;
        *) choice="" ;;
      esac
    fi
    case "${choice}" in
      status)
        if tui_available; then
          local tmp
          tmp="$(mktemp)"
          show_status >"${tmp}"
          whiptail --title " Статус VPS node " --textbox "${tmp}" 30 110 || true
          rm -f "${tmp}"
        else
          show_status
          pause
        fi
        ;;
      collections)
        COLLECTION_SELECTION_MODE="manual"
        select_hub_collections
        run_install_step "$(T "Устанавливаю collections" "Installing collections")" install_collections
        run_install_step "$(T "Проверяю конфигурацию" "Checking configuration")" test_config
        run_install_step "$(T "Перезапускаю сервисы" "Restarting services")" restart_services
        ;;
      hub)
        HUB_ITEM_SELECTION_MODE="manual"
        select_extra_hub_items
        run_install_step "$(T "Устанавливаю дополнительные Hub elements" "Installing additional Hub elements")" install_extra_hub_items
        run_install_step "$(T "Проверяю конфигурацию" "Checking configuration")" test_config
        run_install_step "$(T "Перезапускаю сервисы" "Restarting services")" restart_services
        ;;
      check) show_runtime_checks ;;
      restart) run_install_step "$(T "Перезапускаю сервисы" "Restarting services")" restart_services ;;
      reinstall)
        if [[ ! "$(tui_available && echo yes || echo no)" == "yes" ]] || tui_yesno " Переустановка " "Перезапустить мастер и полностью переустановить/перенастроить VPS node?"; then
          full_install no
          return 0
        fi
        ;;
      language) change_language ;;
      exit) return 0 ;;
      *) warn "$(T "Неизвестный пункт." "Unknown item.")"; pause ;;
    esac
  done
}

main() {
  require_root
  acquire_lock
  if [[ "${1:-}" == "--unattended" || "${CROWDSEC_VPS_UNATTENDED:-no}" == "yes" ]]; then
    export CROWDSEC_VPS_UNATTENDED="yes"
    load_saved_language
    load_env_if_exists
    detect_debian
    full_install yes
    show_status
    return 0
  fi
  bootstrap_installer_tui || true
  choose_language_if_needed
  detect_debian
  require_interactive_install
  if [[ -f "${ENV_FILE}" || -x "$(command -v cscli 2>/dev/null || true)" ]]; then
    load_env_if_exists
    if tui_available; then
      tui_theme
      local mode
      mode="$(whiptail --title " CrowdSec VPS Node " --cancel-button "$(T "Выход" "Exit")" --ok-button "$(T "Выбрать" "Select")" --notags --menu "Найдена существующая установка или настройки VPS node." 16 88 4 \
        "manage" "$(T "Открыть меню управления" "Open management menu")" \
        "reinstall" "$(T "Переустановить/перенастроить полностью" "Reinstall/reconfigure completely")" \
        "install" "$(T "Продолжить обычную установку" "Continue normal installation")" \
        3>&1 1>&2 2>&3)" || exit 0
      case "${mode}" in
        manage) manage_existing_installation; exit 0 ;;
        reinstall) full_install no ;;
        install) full_install no ;;
      esac
    else
      manage_existing_installation
      exit 0
    fi
  else
    full_install no
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
