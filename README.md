# Useful Scripts

## Русский

Набор полезных скриптов для администрирования серверов.

### Оглавление

- [CrowdSec Central + VPS](#crowdsec-central--vps-ru)
- [English](#english)

### CrowdSec Central + VPS {#crowdsec-central--vps-ru}

Каталог: [`crowdsec/`](./crowdsec/)

Версия: `v0.1.0` от `2026-05-22`.

Скрипты:

- [`crowdsec/central.sh`](./crowdsec/central.sh) - установка и управление central-сервером CrowdSec: LAPI, Dockerized CrowdSec, CrowdSec Manager, мастер подключения VPS.
- [`crowdsec/vps.sh`](./crowdsec/vps.sh) - подключение VPS/node к central LAPI, firewall bouncer, выбор и управление CrowdSec Hub collections/scenarios/parsers/appsec/context.

Документация:

- [`crowdsec/README.md`](./crowdsec/README.md)

Быстрый запуск central:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/central.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

Быстрый запуск VPS:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/vps.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

## English

A collection of useful server administration scripts.

### Table Of Contents

- [CrowdSec Central + VPS](#crowdsec-central--vps-en)
- [Русский](#русский)

### CrowdSec Central + VPS {#crowdsec-central--vps-en}

Directory: [`crowdsec/`](./crowdsec/)

Version: `v0.1.0`, released on `2026-05-22`.

Scripts:

- [`crowdsec/central.sh`](./crowdsec/central.sh) - install and manage a CrowdSec central server: LAPI, Dockerized CrowdSec, CrowdSec Manager, VPS onboarding wizard.
- [`crowdsec/vps.sh`](./crowdsec/vps.sh) - connect a VPS/node to central LAPI, firewall bouncer, select/manage CrowdSec Hub collections/scenarios/parsers/appsec/context.

Documentation:

- [`crowdsec/README.md`](./crowdsec/README.md)

Quick start for central:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/central.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

Quick start for VPS:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/vps.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```
