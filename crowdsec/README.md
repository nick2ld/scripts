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
- [CrowdSec Hub: collections, scenarios и остальное](#ru-hub)
- [Повторный запуск и переустановка](#ru-rerun)
- [Файлы и команды](#ru-files)

<a id="ru-purpose"></a>
### Назначение

Этот каталог содержит два Bash-скрипта для схемы с одним центральным CrowdSec LAPI и несколькими VPS/node:

- `central.sh` устанавливает central-сервер: Docker, Dockerized CrowdSec, CrowdSec Manager, LAPI и меню управления.
- `vps.sh` подключает VPS/node к central LAPI, ставит CrowdSec agent, firewall bouncer и выбранные элементы CrowdSec Hub.

Версия обоих скриптов: `v0.1` от `2026-05-22`.

<a id="ru-quick-start"></a>
### Быстрый запуск

Central:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/central.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

VPS/node:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/vps.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

Старые команды с `https://raw.githubusercontent.com/nick2ld/scripts/main/central.sh` и `.../main/vps.sh` неверны после переноса скриптов в каталог `crowdsec/`.

<a id="ru-flow"></a>
### Правильный порядок установки

1. На central-сервере запусти команду установки `central.sh`.
2. После установки открой меню: `sudo crowdsec-central-menu`.
3. В меню открой `Подключения VPS и LAPI -> Создать подключение VPS`.
4. Введи имя VPS и внешний IP этой VPS. Скрипт сам добавит IP в LAPI/UFW как `/32` для IPv4 или `/128` для IPv6.
5. Мастер покажет значения для VPS: `CENTRAL_LAPI_URL`, `AUTO_REG_TOKEN`, `BOUNCER_KEY`, `MACHINE_NAME`.
6. На VPS запусти `vps.sh` и вставь эти значения.
7. В VPS-скрипте выбери CrowdSec Hub collections. Если нужно, включи расширенный выбор Hub elements.

Созданные подключения сохраняются на central в `/root/crowdsec-central/vps-connections.tsv` и просматриваются через `Подключения VPS и LAPI -> Показать созданные подключения`.

<a id="ru-central"></a>
### Что делает central.sh

- Устанавливает Docker и Docker Compose plugin.
- Удаляет apt/systemd CrowdSec перед установкой режима CrowdSec Manager, сохранив backup `/etc/crowdsec` и `/var/lib/crowdsec`.
- Запускает Dockerized CrowdSec и CrowdSec Manager.
- Настраивает central LAPI и auto-registration token.
- Ограничивает Web UI локальными сетями через UFW. Наружу должен быть проброшен только LAPI-порт, если VPS подключаются извне.
- Создаёт индивидуальные bouncer keys для VPS через мастер подключения.
- Показывает прогресс установки в TUI gauge с живым хвостом лога.

В меню оставлен только CrowdSec Manager. Simple Web UI больше не является вариантом установки.

<a id="ru-vps"></a>
### Что делает vps.sh

- Устанавливает CrowdSec agent.
- Удаляет Fail2Ban, если он установлен, предварительно сохранив backup.
- Регистрирует node в central LAPI через `cscli lapi register`.
- Настраивает CrowdSec agent как node, который отправляет события на central LAPI.
- Устанавливает firewall bouncer `iptables` или `nftables` по автоопределению.
- Выбирает CrowdSec Hub collections из реального списка `cscli`, а не из захардкоженных путей логов.
- Предлагает подходящие collections по найденным сервисам, systemd units, Docker containers и Proxmox.
- Позволяет вручную выбрать дополнительные Hub elements.
- Показывает проверку: сервисы, `crowdsec -t`, `cscli lapi status`, Hub items, metrics, alerts.

<a id="ru-hub"></a>
### CrowdSec Hub: collections, scenarios и остальное

Термин “jails” из Fail2Ban здесь не используется буквально. В CrowdSec близкая логика собирается из Hub elements:

- `collections` - наборы для конкретного сервиса или стека. Обычно подтягивают нужные зависимости.
- `scenarios` / attack scenarios - правила поведения, которые определяют атаки.
- `parsers` - разбор логов.
- `postoverflows` - дополнительная обработка после overflow.
- `appsec-configs` - конфигурации AppSec.
- `appsec-rules` - правила AppSec.
- `contexts` - дополнительные поля контекста для событий.

Практичный порядок: сначала ставить `collections`, затем добавлять отдельные `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules`, `contexts`, если collection не покрывает нужный сервис.

Скрипт получает списки через `cscli ... list`. Доступность конкретных типов зависит от версии CrowdSec/cscli и содержимого Hub.

<a id="ru-rerun"></a>
### Повторный запуск и переустановка

Если `vps.sh` запускается повторно и уже есть `/root/crowdsec-vps-node/node.env` или установлен `cscli`, скрипт не обязан заново проходить установку. Он показывает меню:

- показать статус;
- выбрать и установить collections;
- выбрать и установить дополнительные Hub elements;
- проверить сервисы, Hub items, metrics и alerts;
- перезапустить CrowdSec и bouncer;
- переустановить/перенастроить узел полностью.

Ошибка вида `node.env: line 7: crowdsecurity/sshd: No such file or directory` исправлена: значения с пробелами теперь сохраняются через shell-quoting.

<a id="ru-files"></a>
### Файлы и команды

Central:

- меню: `/usr/local/sbin/crowdsec-central-menu`;
- настройки: `/root/crowdsec-central/central.env`;
- созданные подключения VPS: `/root/crowdsec-central/vps-connections.tsv`;
- Docker Compose CrowdSec Manager: `/opt/crowdsec-manager/docker-compose.yml`.

VPS/node:

- настройки: `/root/crowdsec-vps-node/node.env`;
- backup Fail2Ban: `/root/crowdsec-vps-node/fail2ban-backup`;
- CrowdSec config: `/etc/crowdsec/config.yaml`;
- firewall bouncer config: `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`.

<a id="en"></a>
## English

[Русский](#ru)

### Table Of Contents

- [Purpose](#en-purpose)
- [Quick Start](#en-quick-start)
- [Correct Installation Flow](#en-flow)
- [What central.sh Does](#en-central)
- [What vps.sh Does](#en-vps)
- [CrowdSec Hub: collections, scenarios, and more](#en-hub)
- [Rerun and Reinstall](#en-rerun)
- [Files and Commands](#en-files)

<a id="en-purpose"></a>
### Purpose

This directory contains two Bash scripts for a topology with one central CrowdSec LAPI and multiple VPS/node machines:

- `central.sh` installs the central server: Docker, Dockerized CrowdSec, CrowdSec Manager, LAPI, and the management menu.
- `vps.sh` connects a VPS/node to the central LAPI, installs CrowdSec agent, firewall bouncer, and selected CrowdSec Hub elements.

Both scripts version: `v0.1`, released on `2026-05-22`.

<a id="en-quick-start"></a>
### Quick Start

Central:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/central.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

VPS/node:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/vps.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

Old commands with `https://raw.githubusercontent.com/nick2ld/scripts/main/central.sh` and `.../main/vps.sh` are wrong after moving scripts into the `crowdsec/` directory.

<a id="en-flow"></a>
### Correct Installation Flow

1. Run `central.sh` on the central server.
2. After installation, open the menu: `sudo crowdsec-central-menu`.
3. Open `Подключения VPS и LAPI -> Создать подключение VPS`.
4. Enter the VPS name and the VPS public IP. The script adds this IP to LAPI/UFW as `/32` for IPv4 or `/128` for IPv6.
5. The wizard shows values for the VPS: `CENTRAL_LAPI_URL`, `AUTO_REG_TOKEN`, `BOUNCER_KEY`, `MACHINE_NAME`.
6. Run `vps.sh` on the VPS and paste these values.
7. In the VPS script, select CrowdSec Hub collections. Enable advanced Hub element selection when needed.

Created connections are stored on central in `/root/crowdsec-central/vps-connections.tsv` and can be viewed through `Подключения VPS и LAPI -> Показать созданные подключения`.

<a id="en-central"></a>
### What central.sh Does

- Installs Docker and the Docker Compose plugin.
- Removes apt/systemd CrowdSec before installing CrowdSec Manager mode, while backing up `/etc/crowdsec` and `/var/lib/crowdsec`.
- Runs Dockerized CrowdSec and CrowdSec Manager.
- Configures central LAPI and the auto-registration token.
- Restricts Web UI to private networks through UFW. Only the LAPI port should be forwarded from the Internet when external VPS nodes need to connect.
- Creates per-VPS bouncer keys through the onboarding wizard.
- Shows installation progress through a TUI gauge with a live log tail.

CrowdSec Manager is the only Web UI option left in the menu. Simple Web UI is no longer an installation option.

<a id="en-vps"></a>
### What vps.sh Does

- Installs CrowdSec agent.
- Removes Fail2Ban if installed, after creating a backup.
- Registers the node with central LAPI through `cscli lapi register`.
- Configures CrowdSec agent as a node that sends events to central LAPI.
- Installs the `iptables` or `nftables` firewall bouncer based on auto-detection.
- Selects CrowdSec Hub collections from the real `cscli` list instead of hardcoded log paths.
- Suggests matching collections based on detected services, systemd units, Docker containers, and Proxmox.
- Allows manually selecting additional Hub elements.
- Shows checks for services, `crowdsec -t`, `cscli lapi status`, Hub items, metrics, and alerts.

<a id="en-hub"></a>
### CrowdSec Hub: collections, scenarios, and more

The Fail2Ban term “jails” is not used literally in CrowdSec. The closest practical model is built from Hub elements:

- `collections` - bundles for a service or stack. They usually pull required dependencies.
- `scenarios` / attack scenarios - behavior rules that detect attacks.
- `parsers` - log parsing.
- `postoverflows` - additional post-overflow processing.
- `appsec-configs` - AppSec configurations.
- `appsec-rules` - AppSec rules.
- `contexts` - additional event context fields.

Practical flow: install `collections` first, then add standalone `scenarios`, `parsers`, `postoverflows`, `appsec-configs`, `appsec-rules`, or `contexts` only when a collection does not cover the required service.

The script gets lists through `cscli ... list`. Availability of specific types depends on the installed CrowdSec/cscli version and Hub content.

<a id="en-rerun"></a>
### Rerun and Reinstall

If `vps.sh` is run again and `/root/crowdsec-vps-node/node.env` exists or `cscli` is installed, the script does not have to run a full install immediately. It shows a management menu:

- show status;
- select and install collections;
- select and install additional Hub elements;
- check services, Hub items, metrics, and alerts;
- restart CrowdSec and bouncer;
- fully reinstall/reconfigure the node.

The error `node.env: line 7: crowdsecurity/sshd: No such file or directory` is fixed: values containing spaces are now saved using shell-quoting.

<a id="en-files"></a>
### Files and Commands

Central:

- menu: `/usr/local/sbin/crowdsec-central-menu`;
- settings: `/root/crowdsec-central/central.env`;
- created VPS connections: `/root/crowdsec-central/vps-connections.tsv`;
- CrowdSec Manager Docker Compose: `/opt/crowdsec-manager/docker-compose.yml`.

VPS/node:

- settings: `/root/crowdsec-vps-node/node.env`;
- Fail2Ban backup: `/root/crowdsec-vps-node/fail2ban-backup`;
- CrowdSec config: `/etc/crowdsec/config.yaml`;
- firewall bouncer config: `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`.