# CrowdSec Central + VPS Scripts

## Русский

### Что это

Набор интерактивных Bash-скриптов для схемы:

- `central.sh` - центральный CrowdSec LAPI + Dockerized CrowdSec + CrowdSec Manager.
- `vps.sh` - подключение VPS/node к центральному LAPI, установка bouncer и выбор элементов CrowdSec Hub.

### Быстрый запуск

Central:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/central.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

VPS:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/vps.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

### Правильное подключение VPS

1. На central запусти `sudo crowdsec-central-menu`.
2. Открой `Сеть и ключи -> Создать bouncer key с именем VPS`.
3. Введи имя VPS. Это же имя затем укажи в `vps.sh` как `Machine name`.
4. На VPS запусти `vps.sh` и вставь `LAPI URL`, `AUTO_REG_TOKEN`, `BOUNCER_KEY`, `Machine name`.
5. Выбери `collections` из реального списка CrowdSec Hub. При необходимости включи расширенный выбор `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules`, `contexts`.

### Версии

- `central.sh`: `v0.1.0`, дата в `SCRIPT_RELEASE_DATE`.
- `vps.sh`: `v0.1.0`, дата в `SCRIPT_RELEASE_DATE`.

## English

### What This Is

Interactive Bash scripts for:

- `central.sh` - central CrowdSec LAPI + Dockerized CrowdSec + CrowdSec Manager.
- `vps.sh` - connect a VPS/node to the central LAPI, install bouncer, and select CrowdSec Hub items.

### Quick Start

Central:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/central.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

VPS:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/vps.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

### Correct VPS Onboarding Flow

1. On central, run `sudo crowdsec-central-menu`.
2. Open `Network and keys -> Create VPS-named bouncer key`.
3. Enter the VPS name. Use the same value in `vps.sh` as `Machine name`.
4. On the VPS, run `vps.sh` and paste `LAPI URL`, `AUTO_REG_TOKEN`, `BOUNCER_KEY`, `Machine name`.
5. Select `collections` from the real CrowdSec Hub list. Enable advanced selection for `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules`, `contexts` when needed.
