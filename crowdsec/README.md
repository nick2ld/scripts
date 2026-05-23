# CrowdSec Central + VPS Scripts

<a id="ru"></a>
## Русский

[English](#en)

### Оглавление

- [Назначение](#ru-purpose)
- [Быстрый запуск](#ru-quick-start)
- [Правильный порядок установки](#ru-flow)
- [Что делает central.sh](#ru-central)
- [Что делает vps.sh](#ru-vps)
- [CrowdSec Hub](#ru-hub)
- [Повторный запуск и переустановка](#ru-rerun)
- [Файлы и команды](#ru-files)
- [Важно по безопасности](#ru-security)

<a id="ru-purpose"></a>
### Назначение

В каталоге находятся два Bash-скрипта для схемы с одним центральным CrowdSec LAPI и несколькими VPS/node:

- `central.sh` устанавливает центральный сервер: Docker, CrowdSec в Docker, CrowdSec Manager, LAPI и меню управления.
- `vps.sh` подключает VPS/node к центральному LAPI, устанавливает CrowdSec agent, firewall bouncer и выбранные элементы CrowdSec Hub.

Имена файлов и пути остаются прежними:

- `central.sh`
- `vps.sh`

Актуальные версии:

- `central.sh`: `v0.2-secure`
- `vps.sh`: `v0.2-secure-live`

<a id="ru-quick-start"></a>
### Быстрый запуск

Central:

```bash
sh -c 'tmp="$(mktemp -t crowdsec-central.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/central.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

VPS/node:

```bash
sh -c 'tmp="$(mktemp -t crowdsec-vps.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/vps.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

Старые root-level URL без `/crowdsec/` использовать не нужно. Скрипты находятся в каталоге `crowdsec/`.

<a id="ru-flow"></a>
### Правильный порядок установки

1. На central-сервере запусти установку `central.sh`.
2. После установки открой меню:

```bash
sudo crowdsec-central-menu
```

3. В меню открой:

```text
Подключения VPS и LAPI -> Создать подключение VPS
```

4. Введи имя VPS и внешний IP этой VPS.

Скрипт сам добавит IP в доступ к LAPI:

- для IPv4 как `/32`;
- для IPv6 как `/128`.

5. Мастер покажет данные для подключения VPS:

```text
CENTRAL_LAPI_URL
AUTO_REG_TOKEN
BOUNCER_KEY
MACHINE_NAME
```

6. На VPS запусти `vps.sh`.
7. Вставь данные, которые показал central-сервер.
8. Выбери CrowdSec Hub collections.
9. Если нужно, включи расширенный выбор Hub elements.

Созданные подключения сохраняются на central-сервере в файле:

```text
/root/crowdsec-central/vps-connections.tsv
```

Посмотреть их можно через меню:

```text
Подключения VPS и LAPI -> Показать созданные подключения
```

<a id="ru-central"></a>
### Что делает central.sh

`central.sh` устанавливает и настраивает центральный CrowdSec-сервер.

Скрипт выполняет следующие действия:

- устанавливает базовые пакеты;
- устанавливает Docker и Docker Compose plugin;
- создаёт backup старой apt/systemd-версии CrowdSec, если она была установлена;
- удаляет старую apt/systemd-версию CrowdSec перед переходом на Docker-режим;
- запускает Dockerized CrowdSec;
- запускает CrowdSec Manager;
- настраивает central LAPI;
- создаёт auto-registration token;
- создаёт общий bouncer key;
- настраивает UFW;
- ограничивает Web UI локальными сетями;
- разрешает доступ к LAPI только для нужных сетей и VPS;
- устанавливает команду меню `crowdsec-central-menu`;
- создаёт индивидуальные bouncer keys для VPS через мастер подключения.

В меню используется CrowdSec Manager. Simple Web UI больше не используется как вариант установки.

Во время установки и действий из меню скрипт показывает окно с текущим этапом выполнения. Ошибки показываются в отдельном окне с логом.

<a id="ru-vps"></a>
### Что делает vps.sh

`vps.sh` подключает VPS/node к центральному CrowdSec LAPI.

Скрипт выполняет следующие действия:

- устанавливает базовые пакеты;
- устанавливает CrowdSec agent;
- предлагает удалить Fail2Ban, если он найден;
- перед удалением Fail2Ban сохраняет backup;
- проверяет доступность central LAPI;
- регистрирует VPS/node на central LAPI через `cscli lapi register`;
- настраивает CrowdSec agent как node;
- устанавливает CrowdSec collections;
- позволяет выбрать дополнительные Hub elements;
- устанавливает firewall bouncer;
- автоматически выбирает `iptables` или `nftables`;
- подключает firewall bouncer к central LAPI;
- проверяет конфигурацию CrowdSec;
- перезапускает нужные сервисы;
- показывает итоговую сводку.

Во время установки скрипт показывает окно с текущим этапом выполнения. Ошибки показываются в отдельном окне с логом.

<a id="ru-hub"></a>
### CrowdSec Hub

В CrowdSec не используется термин Fail2Ban “jails”. Вместо этого используются элементы CrowdSec Hub.

Основные типы:

- `collections` - наборы правил и зависимостей для конкретного сервиса или стека;
- `scenarios` - сценарии обнаружения атак;
- `parsers` - разбор логов;
- `postoverflows` - дополнительная обработка после срабатывания сценариев;
- `appsec-configs` - конфигурации AppSec;
- `appsec-rules` - правила AppSec;
- `contexts` - дополнительные поля контекста для событий.

Обычный порядок:

1. Сначала установить нужные `collections`.
2. Потом добавить отдельные `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules` или `contexts`, если collection не покрывает нужный сервис.

`vps.sh` получает список collections и Hub elements через `cscli`, а не использует заранее захардкоженный список.

Скрипт может предложить collections по найденным сервисам:

- nginx;
- apache;
- caddy;
- traefik;
- haproxy;
- proxmox;
- docker-контейнеры;
- systemd-сервисы.

<a id="ru-rerun"></a>
### Повторный запуск и переустановка

Если `vps.sh` запускается повторно и уже найден `/root/crowdsec-vps-node/node.env` или установлен `cscli`, скрипт показывает меню управления.

Доступные действия:

- показать статус;
- выбрать и установить collections;
- выбрать и установить дополнительные Hub elements;
- проверить сервисы, Hub items, metrics и alerts;
- перезапустить CrowdSec и bouncer;
- переустановить или перенастроить VPS/node полностью.

Ошибка вида:

```text
node.env: line 7: crowdsecurity/sshd: No such file or directory
```

исправлена. Значения с пробелами сохраняются корректно.

<a id="ru-files"></a>
### Файлы и команды

Central:

```text
/usr/local/sbin/crowdsec-central-menu
/root/crowdsec-central/central.env
/root/crowdsec-central/vps-connections.tsv
/root/crowdsec-central/ufw-backup-*
/opt/crowdsec-manager/docker-compose.yml
```

VPS/node:

```text
/root/crowdsec-vps-node/node.env
/root/crowdsec-vps-node/fail2ban-backup
/etc/crowdsec/config.yaml
/etc/crowdsec/local_api_credentials.yaml
/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
```

Полезные команды на central:

```bash
sudo crowdsec-central-menu
docker ps
docker logs crowdsec
docker logs crowdsec-manager
sudo ufw status verbose
```

Полезные команды на VPS/node:

```bash
sudo systemctl status crowdsec --no-pager -l
sudo cscli lapi status
sudo cscli metrics
sudo systemctl status crowdsec-firewall-bouncer --no-pager -l
sudo journalctl -u crowdsec-firewall-bouncer --no-pager -n 80
```

<a id="ru-security"></a>
### Важно по безопасности

Оба скрипта запускаются от root и меняют системные настройки. Перед запуском желательно использовать отдельную LXC/VM или отдельный VPS.

Что важно знать:

- Web UI не нужно открывать в интернет.
- Наружу пробрасывается только LAPI-порт, если внешние VPS должны подключаться к central.
- Для подключения VPS лучше создавать индивидуальный bouncer key через меню central.
- Если central LAPI доступен через обычный `http://`, лучше использовать VPN, приватную сеть или reverse proxy с HTTPS.
- `central.sh` делает backup UFW перед перенастройкой firewall.
- `vps.sh` делает backup Fail2Ban перед удалением.
- Токены и ключи хранятся в root-only файлах настроек.

<a id="en"></a>
## English

[Русский](#ru)

### Table Of Contents

- [Purpose](#en-purpose)
- [Quick Start](#en-quick-start)
- [Correct Installation Flow](#en-flow)
- [What central.sh Does](#en-central)
- [What vps.sh Does](#en-vps)
- [CrowdSec Hub](#en-hub)
- [Rerun and Reinstall](#en-rerun)
- [Files and Commands](#en-files)
- [Security Notes](#en-security)

<a id="en-purpose"></a>
### Purpose

This directory contains two Bash scripts for a setup with one central CrowdSec LAPI and multiple VPS/node machines:

- `central.sh` installs the central server: Docker, Dockerized CrowdSec, CrowdSec Manager, LAPI, and the management menu.
- `vps.sh` connects a VPS/node to the central LAPI, installs CrowdSec agent, firewall bouncer, and selected CrowdSec Hub elements.

File names and paths stay the same:

- `central.sh`
- `vps.sh`

Current versions:

- `central.sh`: `v0.2-secure`
- `vps.sh`: `v0.2-secure-live`

<a id="en-quick-start"></a>
### Quick Start

Central:

```bash
sh -c 'tmp="$(mktemp -t crowdsec-central.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/central.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

VPS/node:

```bash
sh -c 'tmp="$(mktemp -t crowdsec-vps.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/vps.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

Do not use old root-level URLs without `/crowdsec/`. The scripts are stored in the `crowdsec/` directory.

<a id="en-flow"></a>
### Correct Installation Flow

1. Run `central.sh` on the central server.
2. After installation, open the menu:

```bash
sudo crowdsec-central-menu
```

3. Open:

```text
Подключения VPS и LAPI -> Создать подключение VPS
```

4. Enter the VPS name and the VPS public IP.

The script adds the IP to LAPI access:

- IPv4 as `/32`;
- IPv6 as `/128`.

5. The wizard shows VPS connection values:

```text
CENTRAL_LAPI_URL
AUTO_REG_TOKEN
BOUNCER_KEY
MACHINE_NAME
```

6. Run `vps.sh` on the VPS.
7. Paste the values from the central server.
8. Select CrowdSec Hub collections.
9. Enable advanced Hub element selection if needed.

Created connections are stored on the central server in:

```text
/root/crowdsec-central/vps-connections.tsv
```

They can be viewed from the menu:

```text
Подключения VPS и LAPI -> Показать созданные подключения
```

<a id="en-central"></a>
### What central.sh Does

`central.sh` installs and configures the central CrowdSec server.

The script:

- installs base packages;
- installs Docker and the Docker Compose plugin;
- backs up the old apt/systemd CrowdSec installation if present;
- removes the old apt/systemd CrowdSec installation before switching to Docker mode;
- starts Dockerized CrowdSec;
- starts CrowdSec Manager;
- configures central LAPI;
- creates an auto-registration token;
- creates a shared bouncer key;
- configures UFW;
- restricts Web UI to private networks;
- allows LAPI access only for required networks and VPS nodes;
- installs the `crowdsec-central-menu` command;
- creates per-VPS bouncer keys through the onboarding wizard.

The menu uses CrowdSec Manager. Simple Web UI is no longer used as an installation option.

During installation and menu actions, the script shows the current stage. Errors are shown in a separate log window.

<a id="en-vps"></a>
### What vps.sh Does

`vps.sh` connects a VPS/node to the central CrowdSec LAPI.

The script:

- installs base packages;
- installs CrowdSec agent;
- offers to remove Fail2Ban if it is found;
- creates a Fail2Ban backup before removal;
- checks central LAPI availability;
- registers the VPS/node with central LAPI using `cscli lapi register`;
- configures CrowdSec agent as a node;
- installs CrowdSec collections;
- allows selecting additional Hub elements;
- installs the firewall bouncer;
- automatically selects `iptables` or `nftables`;
- connects the firewall bouncer to central LAPI;
- checks the CrowdSec configuration;
- restarts required services;
- shows the final summary.

During installation, the script shows the current stage. Errors are shown in a separate log window.

<a id="en-hub"></a>
### CrowdSec Hub

CrowdSec does not use the Fail2Ban term “jails”. Instead, it uses CrowdSec Hub elements.

Main types:

- `collections` - rule and dependency bundles for a service or stack;
- `scenarios` - attack detection scenarios;
- `parsers` - log parsing;
- `postoverflows` - additional processing after scenario overflow;
- `appsec-configs` - AppSec configurations;
- `appsec-rules` - AppSec rules;
- `contexts` - additional event context fields.

Normal order:

1. Install the required `collections`.
2. Add standalone `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules`, or `contexts` only if a collection does not cover the required service.

`vps.sh` gets collections and Hub elements through `cscli` instead of using a hardcoded list.

The script can suggest collections based on detected services:

- nginx;
- apache;
- caddy;
- traefik;
- haproxy;
- proxmox;
- docker containers;
- systemd services.

<a id="en-rerun"></a>
### Rerun and Reinstall

If `vps.sh` is run again and `/root/crowdsec-vps-node/node.env` exists or `cscli` is installed, the script shows a management menu.

Available actions:

- show status;
- select and install collections;
- select and install additional Hub elements;
- check services, Hub items, metrics, and alerts;
- restart CrowdSec and bouncer;
- fully reinstall or reconfigure the VPS/node.

This error is fixed:

```text
node.env: line 7: crowdsecurity/sshd: No such file or directory
```

Values containing spaces are saved correctly.

<a id="en-files"></a>
### Files and Commands

Central:

```text
/usr/local/sbin/crowdsec-central-menu
/root/crowdsec-central/central.env
/root/crowdsec-central/vps-connections.tsv
/root/crowdsec-central/ufw-backup-*
/opt/crowdsec-manager/docker-compose.yml
```

VPS/node:

```text
/root/crowdsec-vps-node/node.env
/root/crowdsec-vps-node/fail2ban-backup
/etc/crowdsec/config.yaml
/etc/crowdsec/local_api_credentials.yaml
/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
```

Useful commands on central:

```bash
sudo crowdsec-central-menu
docker ps
docker logs crowdsec
docker logs crowdsec-manager
sudo ufw status verbose
```

Useful commands on VPS/node:

```bash
sudo systemctl status crowdsec --no-pager -l
sudo cscli lapi status
sudo cscli metrics
sudo systemctl status crowdsec-firewall-bouncer --no-pager -l
sudo journalctl -u crowdsec-firewall-bouncer --no-pager -n 80
```

<a id="en-security"></a>
### Security Notes

Both scripts run as root and change system settings. It is recommended to use a separate LXC/VM or a dedicated VPS.

Important notes:

- Do not expose Web UI to the Internet.
- Forward only the LAPI port if external VPS nodes must connect to central.
- Create an individual bouncer key for each VPS through the central menu.
- If central LAPI uses plain `http://`, use VPN, a private network, or a reverse proxy with HTTPS when possible.
- `central.sh` creates a UFW backup before firewall reconfiguration.
- `vps.sh` creates a Fail2Ban backup before removal.
- Tokens and keys are stored in root-only configuration files.
