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
- [Безопасность и ограничения](#ru-security)
- [Файлы и команды](#ru-files)

<a id="ru-purpose"></a>
### Назначение

Этот каталог содержит два Bash-скрипта для схемы с одним центральным CrowdSec LAPI и несколькими VPS/node:

- `central.sh` устанавливает central-сервер: Docker, Dockerized CrowdSec, CrowdSec Manager, LAPI и меню управления.
- `vps.sh` подключает VPS/node к central LAPI, ставит CrowdSec agent, firewall bouncer и выбранные элементы CrowdSec Hub.

Актуальные версии после доработок:

- `central.sh`: `v0.2-secure`.
- `vps.sh`: `v0.2-secure-live`.

Оба скрипта используют TUI-окна с прогресс-баром и живым выводом текущего процесса. Это не статичная имитация: выполняемая команда пишет лог, а окно прогресса показывает обновляемый хвост этого лога. Процент выполнения остаётся приблизительным, потому что `apt`, `docker compose`, `cscli`, `curl`, `systemctl` и другие команды не отдают единый точный процент выполнения.

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

Пути и имена файлов не изменены. Скрипты по-прежнему называются `central.sh` и `vps.sh`.

Старые root-level URL без `/crowdsec/` неверны после переноса скриптов в каталог `crowdsec/`.

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
- Ограничивает Web UI локальными сетями через UFW.
- Разрешает доступ к LAPI из локальных RFC1918-сетей `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.
- Наружу должен быть проброшен только LAPI-порт, если VPS подключаются извне.
- Создаёт индивидуальные bouncer keys для VPS через мастер подключения.
- Показывает прогресс установки и операций в TUI gauge с живым хвостом лога.
- Использует lock-файл, чтобы не допустить одновременный запуск нескольких экземпляров.
- Читает `central.env` безопасным парсером, а не через `source`, чтобы файл настроек не исполнялся как shell-код.
- Перед сбросом UFW создаёт backup текущих правил.
- Перед применением UFW пытается сохранить SSH-доступ: определяет SSH-порты из конфигов и добавляет правило для стандартного порта `22`.
- Если скрипт запущен по SSH, добавляет отдельное правило для текущего SSH-клиента.
- Перед опасной настройкой UFW показывает подтверждение.
- При обновлении меню из GitHub скачивает файл во временное место, проверяет `bash -n`, показывает diff и только после подтверждения заменяет установленный файл.
- При подключении репозитория CrowdSec не использует прямой `curl | sh`: установщик скачивается во временный файл, проверяется через `bash -n` и только потом запускается.
- Перед показом `central.env` предупреждает, что внутри есть токены, пароли и bouncer keys.

В меню оставлен только CrowdSec Manager. Simple Web UI больше не является вариантом установки.

<a id="ru-vps"></a>
### Что делает vps.sh

- Устанавливает CrowdSec agent.
- Проверяет Fail2Ban, создаёт backup и спрашивает подтверждение перед удалением.
- Регистрирует node в central LAPI через `cscli lapi register`.
- Настраивает CrowdSec agent как node, который отправляет события на central LAPI.
- Устанавливает firewall bouncer `iptables` или `nftables` по автоопределению.
- Выбирает CrowdSec Hub collections из реального списка `cscli`, а не из захардкоженных путей логов.
- Предлагает подходящие collections по найденным сервисам, systemd units, Docker containers и Proxmox.
- Позволяет вручную выбрать дополнительные Hub elements.
- Показывает проверку: сервисы, `crowdsec -t`, `cscli lapi status`, Hub items, metrics, alerts.
- Показывает прогресс установки и операций в TUI gauge с живым хвостом лога.
- Использует lock-файл, чтобы не допустить одновременный запуск нескольких экземпляров.
- Очищает временные файлы через `trap`.
- В TUI скрывает ввод `AUTO_REG_TOKEN` и `BOUNCER_KEY` через passwordbox.
- Предупреждает, если `CENTRAL_LAPI_URL` указан через `http://`, потому что токены и bouncer key будут передаваться без TLS.
- При подключении репозитория CrowdSec не использует прямой `curl | sh`: установщик скачивается во временный файл, проверяется через `bash -n` и только потом запускается.

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

Ошибка вида `node.env: line 7: crowdsecurity/sshd: No such file or directory` исправлена: значения с пробелами сохраняются через shell-quoting, а файл настроек читается безопасным парсером.

<a id="ru-security"></a>
### Безопасность и ограничения

Оба скрипта являются root-инсталляторами. Они меняют системные пакеты, сервисы, firewall, Docker, CrowdSec и конфигурационные файлы. Запускать их нужно только на той машине, где действительно планируется установка CrowdSec central или VPS node.

Central-скрипт стал безопаснее, но всё равно остаются важные ограничения:

- `ufw --force reset` всё ещё используется для пересборки firewall-правил, но теперь перед этим создаётся backup и добавляются правила для SSH.
- Docker socket в CrowdSec Manager остаётся потенциально опасным местом, если контейнер или Web UI будут скомпрометированы.
- Образы Docker по тегам не равны pin по digest. Для более строгой безопасности можно закрепить digest конкретного образа.
- Обновление меню из GitHub стало безопаснее за счёт проверки синтаксиса, показа diff и подтверждения, но это всё ещё доверие к удалённому источнику.
- В `central.env` находятся секреты. Файл имеет права `600`, но его нельзя публиковать, пересылать или показывать в скриншотах.

VPS-скрипт стал безопаснее, но тоже имеет ограничения:

- Он работает от root.
- Он устанавливает пакеты через apt.
- Он может удалить Fail2Ban, если пользователь подтвердит удаление.
- Firewall bouncer может блокировать IP по решениям central LAPI.
- Если central LAPI работает через `http://`, токены и bouncer key передаются без шифрования. Лучше использовать VPN, приватную сеть или HTTPS/reverse proxy.
- Внешний установщик CrowdSec теперь не запускается через прямой pipe в shell, но всё равно скачивается и выполняется локально после проверки синтаксиса.

Рекомендуемый безопасный вариант: central LAPI держать в приватной сети или VPN, Web UI наружу не пробрасывать, LAPI наружу открывать только при необходимости и только для IP конкретных VPS.

<a id="ru-files"></a>
### Файлы и команды

Central:

- меню: `/usr/local/sbin/crowdsec-central-menu`;
- настройки: `/root/crowdsec-central/central.env`;
- созданные подключения VPS: `/root/crowdsec-central/vps-connections.tsv`;
- backup UFW перед reset: `/root/crowdsec-central/ufw-backup-ДАТА-ВРЕМЯ/`;
- Docker Compose CrowdSec Manager: `/opt/crowdsec-manager/docker-compose.yml`.

VPS/node:

- настройки: `/root/crowdsec-vps-node/node.env`;
- backup Fail2Ban: `/root/crowdsec-vps-node/fail2ban-backup`;
- lock-файл запуска: `/var/lock/crowdsec-vps-node.lock`;
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
- [Security and Limitations](#en-security)
- [Files and Commands](#en-files)

<a id="en-purpose"></a>
### Purpose

This directory contains two Bash scripts for a topology with one central CrowdSec LAPI and multiple VPS/node machines:

- `central.sh` installs the central server: Docker, Dockerized CrowdSec, CrowdSec Manager, LAPI, and the management menu.
- `vps.sh` connects a VPS/node to the central LAPI, installs CrowdSec agent, firewall bouncer, and selected CrowdSec Hub elements.

Current versions after the security/live-progress updates:

- `central.sh`: `v0.2-secure`.
- `vps.sh`: `v0.2-secure-live`.

Both scripts use TUI progress windows with live command output. This is not a static animation: the running command writes to a log, and the progress window shows the updated tail of that log. The percentage is still approximate because `apt`, `docker compose`, `cscli`, `curl`, `systemctl`, and other commands do not expose one unified accurate progress value.

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

Paths and filenames are unchanged. The scripts are still named `central.sh` and `vps.sh`.

Old root-level URLs without `/crowdsec/` are wrong after moving scripts into the `crowdsec/` directory.

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
- Restricts Web UI to private networks through UFW.
- Allows LAPI access from local RFC1918 networks: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.
- Only the LAPI port should be forwarded from the Internet when external VPS nodes need to connect.
- Creates per-VPS bouncer keys through the onboarding wizard.
- Shows installation and operation progress through a TUI gauge with a live log tail.
- Uses a lock file to prevent multiple concurrent script instances.
- Reads `central.env` through a safe parser instead of `source`, so the settings file is not executed as shell code.
- Creates a backup of current UFW rules before resetting UFW.
- Tries to preserve SSH access before applying UFW by detecting SSH ports from configuration files and always adding the standard `22` port.
- If the script is running over SSH, adds a separate rule for the current SSH client.
- Asks for confirmation before dangerous UFW changes.
- When updating the installed menu from GitHub, downloads to a temporary file, checks `bash -n`, shows a diff, and replaces the installed file only after confirmation.
- Does not use direct `curl | sh` for the CrowdSec repository installer: it downloads the installer to a temporary file, checks it with `bash -n`, and then runs it.
- Warns before displaying `central.env` because it contains tokens, passwords, and bouncer keys.

CrowdSec Manager is the only Web UI option left in the menu. Simple Web UI is no longer an installation option.

<a id="en-vps"></a>
### What vps.sh Does

- Installs CrowdSec agent.
- Checks for Fail2Ban, creates a backup, and asks for confirmation before removal.
- Registers the node with central LAPI through `cscli lapi register`.
- Configures CrowdSec agent as a node that sends events to central LAPI.
- Installs the `iptables` or `nftables` firewall bouncer based on auto-detection.
- Selects CrowdSec Hub collections from the real `cscli` list instead of hardcoded log paths.
- Suggests matching collections based on detected services, systemd units, Docker containers, and Proxmox.
- Allows manually selecting additional Hub elements.
- Shows checks for services, `crowdsec -t`, `cscli lapi status`, Hub items, metrics, and alerts.
- Shows installation and operation progress through a TUI gauge with a live log tail.
- Uses a lock file to prevent multiple concurrent script instances.
- Cleans temporary files through `trap`.
- Hides `AUTO_REG_TOKEN` and `BOUNCER_KEY` entry in TUI through password boxes.
- Warns if `CENTRAL_LAPI_URL` uses `http://`, because tokens and the bouncer key are sent without TLS.
- Does not use direct `curl | sh` for the CrowdSec repository installer: it downloads the installer to a temporary file, checks it with `bash -n`, and then runs it.

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

The error `node.env: line 7: crowdsecurity/sshd: No such file or directory` is fixed: values containing spaces are saved using shell-quoting, and the settings file is read through a safe parser.

<a id="en-security"></a>
### Security and Limitations

Both scripts are root installers. They modify system packages, services, firewall, Docker, CrowdSec, and configuration files. Run them only on the machine where CrowdSec central or VPS node installation is actually intended.

The central script is safer now, but important limitations remain:

- `ufw --force reset` is still used to rebuild firewall rules, but current rules are backed up first and SSH rules are added before enabling UFW.
- The Docker socket in CrowdSec Manager remains a sensitive point if the container or Web UI is compromised.
- Docker image tags are not the same as digest pinning. For stricter security, pin exact image digests.
- Updating the menu from GitHub is safer due to syntax checking, diff display, and confirmation, but it still trusts a remote source.
- `central.env` contains secrets. It has `600` permissions, but it must not be published, sent, or exposed in screenshots.

The VPS script is safer now, but also has limitations:

- It runs as root.
- It installs packages through apt.
- It may remove Fail2Ban if the user confirms removal.
- Firewall bouncer may block IPs based on central LAPI decisions.
- If central LAPI uses `http://`, tokens and the bouncer key are sent without encryption. Prefer VPN, a private network, or HTTPS/reverse proxy.
- The external CrowdSec installer is no longer run through a direct pipe to shell, but it is still downloaded and executed locally after a syntax check.

Recommended safer setup: keep central LAPI on a private network or VPN, do not expose Web UI to the Internet, and expose LAPI only when required and only to specific VPS IPs.

<a id="en-files"></a>
### Files and Commands

Central:

- menu: `/usr/local/sbin/crowdsec-central-menu`;
- settings: `/root/crowdsec-central/central.env`;
- created VPS connections: `/root/crowdsec-central/vps-connections.tsv`;
- UFW backup before reset: `/root/crowdsec-central/ufw-backup-DATE-TIME/`;
- CrowdSec Manager Docker Compose: `/opt/crowdsec-manager/docker-compose.yml`.

VPS/node:

- settings: `/root/crowdsec-vps-node/node.env`;
- Fail2Ban backup: `/root/crowdsec-vps-node/fail2ban-backup`;
- run lock file: `/var/lock/crowdsec-vps-node.lock`;
- CrowdSec config: `/etc/crowdsec/config.yaml`;
- firewall bouncer config: `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`.
