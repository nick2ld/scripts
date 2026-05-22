# Useful Scripts

<a id="ru"></a>
## Русский

Репозиторий задуман как каталог полезных серверных скриптов. Каждый набор скриптов лежит в отдельном каталоге со своей документацией.

### Оглавление

- [Каталог скриптов](#ru-catalog)
- [CrowdSec Central + VPS](#ru-crowdsec)
- [English](#en)

<a id="ru-catalog"></a>
### Каталог скриптов

| Набор | Каталог | Описание |
| --- | --- | --- |
| CrowdSec Central + VPS | [`crowdsec/`](./crowdsec/) | Установка central-сервера CrowdSec Manager и подключение VPS/node к центральному LAPI. |

<a id="ru-crowdsec"></a>
### CrowdSec Central + VPS

Версия: `v0.1` от `2026-05-22`.

Файлы:

- [`crowdsec/central.sh`](./crowdsec/central.sh) - central-сервер: Dockerized CrowdSec, LAPI, CrowdSec Manager, мастер подключения VPS.
- [`crowdsec/vps.sh`](./crowdsec/vps.sh) - VPS/node: подключение к central LAPI, firewall bouncer, выбор и управление CrowdSec Hub elements.
- [`crowdsec/README.md`](./crowdsec/README.md) - подробная документация на русском и английском.

Быстрый запуск central:

```bash
sh -c 'tmp="$(mktemp -t crowdsec-central.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/central.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

Быстрый запуск VPS/node:

```bash
sh -c 'tmp="$(mktemp -t crowdsec-vps.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/vps.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

Важно: root-level URL без `/crowdsec/` больше не используются. Скрипты находятся в каталоге `crowdsec/`.

<a id="en"></a>
## English

This repository is a catalog of useful server scripts. Each script set lives in its own directory with dedicated documentation.

### Table Of Contents

- [Script Catalog](#en-catalog)
- [CrowdSec Central + VPS](#en-crowdsec)
- [Русский](#ru)

<a id="en-catalog"></a>
### Script Catalog

| Set | Directory | Description |
| --- | --- | --- |
| CrowdSec Central + VPS | [`crowdsec/`](./crowdsec/) | Install a CrowdSec Manager central server and connect VPS/node machines to the central LAPI. |

<a id="en-crowdsec"></a>
### CrowdSec Central + VPS

Version: `v0.1`, released on `2026-05-22`.

Files:

- [`crowdsec/central.sh`](./crowdsec/central.sh) - central server: Dockerized CrowdSec, LAPI, CrowdSec Manager, VPS onboarding wizard.
- [`crowdsec/vps.sh`](./crowdsec/vps.sh) - VPS/node: connect to central LAPI, firewall bouncer, select and manage CrowdSec Hub elements.
- [`crowdsec/README.md`](./crowdsec/README.md) - detailed documentation in Russian and English.

Quick start for central:

```bash
sh -c 'tmp="$(mktemp -t crowdsec-central.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/central.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

Quick start for VPS/node:

```bash
sh -c 'tmp="$(mktemp -t crowdsec-vps.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/vps.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

Note: root-level URLs without `/crowdsec/` are no longer used. Scripts are under the `crowdsec/` directory.
