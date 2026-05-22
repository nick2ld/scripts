# CrowdSec Central + VPS Scripts

## Русский

[English](#english)

### Что это

Набор интерактивных Bash-скриптов для схемы:

- `central.sh` - центральный CrowdSec LAPI + Dockerized CrowdSec + CrowdSec Manager.
- `vps.sh` - подключение VPS/node к central LAPI, установка firewall bouncer, выбор и управление CrowdSec Hub elements.

Версия обоих скриптов: `v0.1.0` от `2026-05-22`.

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
2. Открой `Подключения VPS и LAPI -> Создать подключение VPS`.
3. Введи имя VPS и его внешний IP. Скрипт сам добавит IP в LAPI/UFW как `/32` или `/128` и создаст bouncer key.
4. На VPS запусти `vps.sh` и вставь `LAPI URL`, `AUTO_REG_TOKEN`, `BOUNCER_KEY`, `Machine name` из созданной записи.
5. Выбери `collections` из реального списка CrowdSec Hub. При необходимости включи расширенный выбор `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules`, `contexts`.

Созданные подключения сохраняются на central в `/root/crowdsec-central/vps-connections.tsv` и доступны через меню.

### Что реализовано

- Только CrowdSec Manager для веб-морды. Старые варианты Simple Web UI больше не предлагаются в меню установки.
- Установка CrowdSec Manager с Dockerized CrowdSec и удалением apt/systemd CrowdSec перед миграцией.
- Мастер подключения VPS: имя, IP, LAPI access, bouncer key и сохранение записи.
- Прогресс установки через TUI gauge с живым хвостом логов.
- Выбор CrowdSec Hub `collections` из реального списка `cscli`, не из захардкоженных путей логов.
- Расширенный выбор Hub elements: `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules`, `contexts`.
- Повторный запуск VPS-скрипта открывает меню управления или переустановки, а не ломается на `node.env`.
- Автоопределение популярных сервисов, Docker-контейнеров и Proxmox с предложением подходящих collections, если они есть в Hub.
- Проверка VPS node: сервисы, `crowdsec -t`, LAPI status, installed Hub items, metrics, alerts.

### Важное про scenarios / attack scenarios

В CrowdSec атаки описываются в `scenarios`. `collections` обычно подтягивают нужные `parsers`, `scenarios` и другие зависимости. Поэтому нормальный путь такой: сначала выбрать `collections`, затем при необходимости вручную добавить отдельные Hub elements.

### Версии

- `central.sh`: `v0.1.0`, дата в `SCRIPT_RELEASE_DATE`.
- `vps.sh`: `v0.1.0`, дата в `SCRIPT_RELEASE_DATE`.

## English

[Русский](#русский)

### What This Is

Interactive Bash scripts for:

- `central.sh` - central CrowdSec LAPI + Dockerized CrowdSec + CrowdSec Manager.
- `vps.sh` - connect a VPS/node to central LAPI, install firewall bouncer, and select/manage CrowdSec Hub items.

Both scripts version: `v0.1.0`, released on `2026-05-22`.

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
2. Open `VPS connections and LAPI -> Create VPS connection`.
3. Enter the VPS name and its public IP. The script adds this IP to LAPI/UFW as `/32` or `/128` and creates a bouncer key.
4. On the VPS, run `vps.sh` and paste `LAPI URL`, `AUTO_REG_TOKEN`, `BOUNCER_KEY`, `Machine name` from the saved record.
5. Select `collections` from the real CrowdSec Hub list. Enable advanced selection for `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules`, `contexts` when needed.

Created connections are stored on central in `/root/crowdsec-central/vps-connections.tsv` and can be viewed from the menu.

### Implemented

- CrowdSec Manager is the only Web UI exposed by the installer/menu.
- CrowdSec Manager installs with Dockerized CrowdSec and removes apt/systemd CrowdSec during migration.
- VPS onboarding wizard: name, IP, LAPI access, bouncer key, saved connection record.
- Installer progress through a TUI gauge with live log tail.
- CrowdSec Hub `collections` are selected from the real `cscli` list, not from hardcoded log paths.
- Advanced Hub item selection: `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules`, `contexts`.
- Rerunning the VPS script opens a management/reinstall menu and no longer breaks on `node.env`.
- Automatic detection of common services, Docker containers, and Proxmox with matching Hub collection suggestions when available.
- VPS node checks: services, `crowdsec -t`, LAPI status, installed Hub items, metrics, alerts.

### Note About Scenarios / Attack Scenarios

In CrowdSec, attacks are represented by `scenarios`. `collections` usually pull the required `parsers`, `scenarios`, and related dependencies. The practical flow is to install collections first, then add standalone Hub items only when needed.
