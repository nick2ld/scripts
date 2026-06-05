[Русский](#ru) | [English](#en)

# CrowdSec Central + VPS Scripts

<a id="ru"></a>
## Русский

[English](#en)

### Назначение

В этом каталоге находятся два скрипта для установки CrowdSec в схеме с одним центральным сервером и несколькими VPS.

`central.sh` устанавливает центральный сервер CrowdSec: Docker, CrowdSec в контейнере, CrowdSec Manager, LAPI и меню управления.

`vps.sh` подключает отдельную VPS к центральному CrowdSec LAPI, устанавливает CrowdSec agent, firewall bouncer и выбранные элементы CrowdSec Hub.

Имена файлов и пути запуска остаются прежними:

```bash
crowdsec/central.sh
crowdsec/vps.sh
```

### Быстрый запуск

Сначала запускается `central.sh` на центральном сервере.

```bash
sh -c 'tmp="$(mktemp -t crowdsec-central.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/central.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

После настройки central-сервера запускается `vps.sh` на каждой VPS, которую нужно подключить.

```bash
sh -c 'tmp="$(mktemp -t crowdsec-vps.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/vps.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

### Правильный порядок установки

1. Запусти `central.sh` на центральном сервере.
2. После установки открой меню central-сервера:

```bash
sudo crowdsec-central-menu
```

3. В меню создай подключение для VPS.
4. Укажи имя VPS и внешний IP этой VPS.
5. Central-сервер покажет данные для подключения VPS.
6. Запусти `vps.sh` на VPS.
7. Вставь данные, которые показал central-сервер.
8. Выбери нужные CrowdSec Hub collections.
9. После завершения проверь статус через меню или команды проверки.

### Что устанавливает central.sh

`central.sh` устанавливает и настраивает:

- Docker;
- Docker Compose plugin;
- CrowdSec в Docker;
- CrowdSec Manager;
- central LAPI;
- меню управления `crowdsec-central-menu`;
- правила UFW для Web UI и LAPI;
- хранение подключений VPS.

После установки Web UI доступен только из локальной сети. Наружу нужно пробрасывать только LAPI-порт и только если внешние VPS должны подключаться к central-серверу.

### CrowdSec Manager: Docker image или GitHub release

По умолчанию central-скрипт использует Docker image:

```bash
hhftechnology/crowdsec-manager:independent
```

Если нужен последний опубликованный release из GitHub, открой меню:

```bash
sudo crowdsec-central-menu
```

Дальше выбери:

```text
Быстрый старт и восстановление -> Выбрать источник CrowdSec Manager
```

Доступны три режима:

- официальный Docker image `independent`;
- сборка последнего GitHub release;
- сборка конкретного GitHub tag.

В режиме GitHub release скрипт получает `latest` release через GitHub API, скачивает tarball релиза, собирает локальный Docker image и прописывает его в `/opt/crowdsec-manager/docker-compose.yml`.

Выбор сохраняется в:

```bash
/root/crowdsec-central/central.env
```

Ключи:

```bash
MANAGER_IMAGE_MODE=image|github_latest|github_tag
MANAGER_GITHUB_TAG=v2.3.2
```

### Что изменено в central.sh

В текущей версии central-скрипта добавлены улучшения:

- установка и действия меню показываются в TUI-окнах;
- долгие операции выводятся в отдельном окне установки;
- настройки `central.env` читаются безопаснее;
- добавлена защита от одновременного запуска нескольких копий скрипта;
- перед изменением UFW сохраняется backup правил;
- перед опасными действиями с firewall показывается предупреждение;
- обновление меню из GitHub выполняется только после проверки и подтверждения;
- просмотр файла с токенами сопровождается предупреждением;
- добавлен выбор источника CrowdSec Manager: Docker image, latest GitHub release или конкретный GitHub tag;
- обновление CrowdSec Manager отделено от обновления Dockerized CrowdSec engine;
- меню central-сервера закреплено в понятной иерархии: быстрый старт, VPS, защита, сеть, статус, обновления, настройки интерфейса.

### Структура меню central-сервера

Главное меню `sudo crowdsec-central-menu` разделено по задачам:

- `Быстрый старт и восстановление` - чистая установка, восстановление stack, выбор источника Manager, базовая защита, первое подключение VPS.
- `Подключения VPS` - создание подключения, подтверждение ожидающей VPS, просмотр созданных подключений.
- `Защита и правила CrowdSec` - базовая защита, CrowdSec Hub, ручные блокировки, доверенные IP/CIDR, CrowdSec Console.
- `Сеть и доступ к LAPI` - Web UI, порт LAPI, публичный HTTPS URL, прямой внешний адрес, разрешённые IP/CIDR, ключи.
- `Статус, логи и диагностика` - сервисы, порты, логи, firewall/UFW, версии, central.env.
- `Обновления и обслуживание` - обновление Manager, CrowdSec engine, всего stack, Docker, системных пакетов, переустановка команды меню.
- `Настройки интерфейса` - язык и автозапуск меню при входе в shell.

### Что устанавливает vps.sh

`vps.sh` устанавливает и настраивает:

- CrowdSec agent;
- регистрацию VPS на central LAPI;
- работу CrowdSec agent как node;
- firewall bouncer;
- выбранные CrowdSec Hub collections;
- дополнительные Hub elements, если они выбраны вручную;
- проверку сервисов и статуса CrowdSec.

Fail2Ban может быть удалён только после backup и подтверждения. Это нужно, чтобы избежать конфликта между Fail2Ban и CrowdSec firewall bouncer.

### Что изменено в vps.sh

В текущей версии VPS-скрипта добавлены улучшения:

- установка проходит через TUI-окна;
- токены вводятся в скрытом поле;
- добавлена защита от одновременного запуска нескольких копий скрипта;
- добавлено предупреждение при использовании `http://` для central LAPI;
- установщик CrowdSec сначала скачивается во временный файл и проверяется;
- удаление Fail2Ban требует подтверждения;
- временные файлы очищаются автоматически;
- повторный запуск открывает меню управления существующей установкой.

### CrowdSec Hub

CrowdSec Hub содержит готовые элементы защиты для разных сервисов.

Обычно достаточно выбрать нужные `collections`. Они подтягивают связанные правила и парсеры.

Дополнительные элементы Hub можно выбирать вручную, если нужно точнее настроить защиту под конкретный сервис.

Скрипт может предложить collections на основе найденных сервисов, systemd units, Docker containers и Proxmox.

### Повторный запуск

Если `central.sh` уже установлен, управление выполняется через:

```bash
sudo crowdsec-central-menu
```

Если `vps.sh` запускается повторно на уже настроенной VPS, скрипт откроет меню управления.

В меню VPS можно:

- посмотреть статус;
- выбрать и установить collections;
- установить дополнительные Hub elements;
- проверить сервисы и метрики;
- перезапустить CrowdSec и firewall bouncer;
- выполнить переустановку или перенастройку.

### Где лежат файлы central-сервера

Меню:

```bash
/usr/local/sbin/crowdsec-central-menu
```

Настройки:

```bash
/root/crowdsec-central/central.env
```

Список созданных подключений VPS:

```bash
/root/crowdsec-central/vps-connections.tsv
```

Docker Compose:

```bash
/opt/crowdsec-manager/docker-compose.yml
```

Backup UFW:

```bash
/root/crowdsec-central/ufw-backup-*
```

### Где лежат файлы VPS

Настройки VPS:

```bash
/root/crowdsec-vps-node/node.env
```

Backup Fail2Ban:

```bash
/root/crowdsec-vps-node/fail2ban-backup
```

Конфиг CrowdSec:

```bash
/etc/crowdsec/config.yaml
```

Конфиг firewall bouncer:

```bash
/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
```

### Полезные команды

Проверить CrowdSec на VPS:

```bash
sudo systemctl status crowdsec --no-pager -l
sudo cscli lapi status
sudo cscli metrics
```

Проверить firewall bouncer на VPS:

```bash
sudo systemctl status crowdsec-firewall-bouncer --no-pager -l
sudo journalctl -u crowdsec-firewall-bouncer --no-pager -n 80
```

Проверить подключённые машины на central-сервере:

```bash
sudo cscli machines list
sudo cscli alerts list
sudo cscli decisions list
```

### Важно

Скрипты нужно запускать от root или через sudo.

Перед установкой желательно иметь доступ к серверу через консоль провайдера или гипервизора. Это особенно важно при изменении firewall.

Не публикуй содержимое файлов `central.env` и `node.env`. В них находятся токены и ключи доступа.

Для подключения VPS к central LAPI лучше использовать VPN, приватную сеть или HTTPS. Если используется обычный `http://`, данные подключения передаются без шифрования.

<a id="en"></a>
## English

[Русский](#ru)

### Purpose

This directory contains two scripts for a CrowdSec setup with one central server and multiple VPS nodes.

`central.sh` installs the central CrowdSec server: Docker, Dockerized CrowdSec, CrowdSec Manager, LAPI, and the management menu.

`vps.sh` connects a VPS node to the central CrowdSec LAPI, installs the CrowdSec agent, firewall bouncer, and selected CrowdSec Hub elements.

File names and launch paths stay the same:

```bash
crowdsec/central.sh
crowdsec/vps.sh
```

### Quick Start

Run `central.sh` first on the central server.

```bash
sh -c 'tmp="$(mktemp -t crowdsec-central.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/central.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

After the central server is ready, run `vps.sh` on every VPS node you want to connect.

```bash
sh -c 'tmp="$(mktemp -t crowdsec-vps.XXXXXX)" && curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/refs/heads/main/crowdsec/vps.sh" -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit "$rc"'
```

### Correct Installation Order

1. Run `central.sh` on the central server.
2. After installation, open the central menu:

```bash
sudo crowdsec-central-menu
```

3. Create a VPS connection in the menu.
4. Enter the VPS name and the VPS public IP.
5. The central server will show the connection data for the VPS.
6. Run `vps.sh` on the VPS.
7. Paste the values shown by the central server.
8. Select the required CrowdSec Hub collections.
9. After installation, check the status through the menu or with the verification commands.

### What central.sh Installs

`central.sh` installs and configures:

- Docker;
- Docker Compose plugin;
- CrowdSec in Docker;
- CrowdSec Manager;
- central LAPI;
- the `crowdsec-central-menu` management menu;
- UFW rules for Web UI and LAPI;
- saved VPS connection records.

After installation, the Web UI is intended for local network access only. Only the LAPI port should be forwarded from the Internet, and only when external VPS nodes need to connect.

### CrowdSec Manager: Docker Image or GitHub Release

By default, the central script uses this Docker image:

```bash
hhftechnology/crowdsec-manager:independent
```

To build the latest published GitHub release, open the menu:

```bash
sudo crowdsec-central-menu
```

Then select:

```text
Quick start and recovery -> Choose CrowdSec Manager source
```

Available modes:

- official `independent` Docker image;
- build latest GitHub release;
- build specific GitHub tag.

In GitHub release mode, the script reads the `latest` release through the GitHub API, downloads the release tarball, builds a local Docker image, and writes it to `/opt/crowdsec-manager/docker-compose.yml`.

The selected source is stored in:

```bash
/root/crowdsec-central/central.env
```

Keys:

```bash
MANAGER_IMAGE_MODE=image|github_latest|github_tag
MANAGER_GITHUB_TAG=v2.3.2
```

### What Changed in central.sh

The current central script includes these improvements:

- installation and menu actions are shown in TUI windows;
- long operations are displayed in a separate installation window;
- `central.env` is read more safely;
- protection against running multiple script instances at the same time;
- UFW rules are backed up before changes;
- dangerous firewall actions show a warning first;
- menu updates from GitHub require validation and confirmation;
- viewing the token file shows a warning;
- CrowdSec Manager source selection: Docker image, latest GitHub release, or specific GitHub tag;
- CrowdSec Manager update is separated from Dockerized CrowdSec engine update;
- the central server menu is fixed into a clear hierarchy: quick start, VPS, protection, network, status, updates, interface settings.

### Central Server Menu Structure

The main `sudo crowdsec-central-menu` menu is organized by task:

- `Quick start and recovery` - clean install, stack repair, Manager source, base protection, first VPS connection.
- `VPS connections` - create a connection, validate a pending VPS, view created connections.
- `CrowdSec protection and rules` - base protection, CrowdSec Hub, manual blocks, trusted IP/CIDR, CrowdSec Console.
- `Network and LAPI access` - Web UI, LAPI port, public HTTPS URL, direct public address, allowed IP/CIDR, keys.
- `Status, logs and diagnostics` - services, ports, logs, firewall/UFW, versions, central.env.
- `Updates and maintenance` - update Manager, CrowdSec engine, full stack, Docker, system packages, reinstall the menu command.
- `Interface settings` - language and menu autostart on shell login.

### What vps.sh Installs

`vps.sh` installs and configures:

- CrowdSec agent;
- VPS registration with the central LAPI;
- CrowdSec agent node mode;
- firewall bouncer;
- selected CrowdSec Hub collections;
- additional Hub elements when selected manually;
- service and CrowdSec status checks.

Fail2Ban can be removed only after backup and confirmation. This helps avoid conflicts between Fail2Ban and the CrowdSec firewall bouncer.

### What Changed in vps.sh

The current VPS script includes these improvements:

- installation uses TUI windows;
- tokens are entered in hidden fields;
- protection against running multiple script instances at the same time;
- warning when `http://` is used for the central LAPI;
- the CrowdSec installer is downloaded to a temporary file and checked before execution;
- Fail2Ban removal requires confirmation;
- temporary files are cleaned automatically;
- rerunning the script opens a management menu for the existing installation.

### CrowdSec Hub

CrowdSec Hub contains ready-made protection elements for different services.

Usually, selecting the required `collections` is enough. Collections pull related rules and parsers.

Additional Hub elements can be selected manually when you need more precise protection for a specific service.

The script can suggest collections based on detected services, systemd units, Docker containers, and Proxmox.

### Rerun

If `central.sh` is already installed, manage it with:

```bash
sudo crowdsec-central-menu
```

If `vps.sh` is run again on an already configured VPS, it opens the management menu.

In the VPS menu, you can:

- view status;
- select and install collections;
- install additional Hub elements;
- check services and metrics;
- restart CrowdSec and firewall bouncer;
- reinstall or reconfigure the node.

### Central Server Files

Menu:

```bash
/usr/local/sbin/crowdsec-central-menu
```

Settings:

```bash
/root/crowdsec-central/central.env
```

Saved VPS connections:

```bash
/root/crowdsec-central/vps-connections.tsv
```

Docker Compose:

```bash
/opt/crowdsec-manager/docker-compose.yml
```

UFW backup:

```bash
/root/crowdsec-central/ufw-backup-*
```

### VPS Files

VPS settings:

```bash
/root/crowdsec-vps-node/node.env
```

Fail2Ban backup:

```bash
/root/crowdsec-vps-node/fail2ban-backup
```

CrowdSec config:

```bash
/etc/crowdsec/config.yaml
```

Firewall bouncer config:

```bash
/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
```

### Useful Commands

Check CrowdSec on the VPS:

```bash
sudo systemctl status crowdsec --no-pager -l
sudo cscli lapi status
sudo cscli metrics
```

Check firewall bouncer on the VPS:

```bash
sudo systemctl status crowdsec-firewall-bouncer --no-pager -l
sudo journalctl -u crowdsec-firewall-bouncer --no-pager -n 80
```

Check connected machines on the central server:

```bash
sudo cscli machines list
sudo cscli alerts list
sudo cscli decisions list
```

### Important

Run the scripts as root or through sudo.

Before installation, make sure you have access to the server console through your provider or hypervisor. This is especially important when firewall rules are changed.

Do not publish the contents of `central.env` or `node.env`. They contain tokens and access keys.

For VPS connections to the central LAPI, VPN, a private network, or HTTPS is recommended. If plain `http://` is used, connection data is sent without encryption.
