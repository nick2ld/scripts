# CrowdSec Scripts

Production-ready Bash scripts for deploying and operating CrowdSec in a central + node architecture.

## Repository Contents

- `central.sh` - installs and manages CrowdSec Central LAPI + Web UI on Debian/Ubuntu.
- `vps.sh` - installs and connects a VPS CrowdSec node to a central LAPI.

## Requirements

- OS: Debian/Ubuntu (or Debian-based)
- Run as root (`sudo`)
- Internet access for package installation

## Quick Start

### One-command install from GitHub

Use the temporary-file form below. It keeps stdin attached to the terminal, so the installer can ask interactive questions correctly.

Central server:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/central.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

VPS node:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/nick2ld/scripts/main/vps.sh -o "$tmp" && if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; [ "$rc" -eq 0 ]
```

Alternative with `wget`:

```bash
wget -qO /tmp/crowdsec-central.sh https://raw.githubusercontent.com/nick2ld/scripts/main/central.sh && if [ "$(id -u)" -eq 0 ]; then bash /tmp/crowdsec-central.sh; else sudo bash /tmp/crowdsec-central.sh; fi; rc=$?; rm -f /tmp/crowdsec-central.sh; [ "$rc" -eq 0 ]
```

For VPS node with `wget`:

```bash
wget -qO /tmp/crowdsec-vps.sh https://raw.githubusercontent.com/nick2ld/scripts/main/vps.sh && if [ "$(id -u)" -eq 0 ]; then bash /tmp/crowdsec-vps.sh; else sudo bash /tmp/crowdsec-vps.sh; fi; rc=$?; rm -f /tmp/crowdsec-vps.sh; [ "$rc" -eq 0 ]
```

### 1) Central server

```bash
sudo bash central.sh
```

After installation, interactive menu:

```bash
sudo crowdsec-central-menu
```

Update installed menu command without reinstalling the stack:

```bash
sudo curl -fsSL "https://raw.githubusercontent.com/nick2ld/scripts/main/central.sh?$(date +%s)" -o /usr/local/sbin/crowdsec-central-menu && sudo chmod 755 /usr/local/sbin/crowdsec-central-menu
```

### 2) VPS node

```bash
sudo bash vps.sh
```

You will need values from central server menu:
- `LAPI URL`
- `AUTO_REG_TOKEN`
- `SHARED_BOUNCER_KEY`

## What These Scripts Configure

### `central.sh`
- CrowdSec LAPI listening on configured port
- Auto-registration token and allowed CIDR ranges
- Shared bouncer key for remote nodes
- Docker + CrowdSec Web UI
- UFW rules for Web UI and LAPI
- Interactive management menu

### `vps.sh`
- CrowdSec agent installation
- Fail2Ban safe removal (with backup)
- Node registration to central LAPI
- Optional web log collections
- Firewall bouncer connection to central LAPI

## Security Notes

- Keep `AUTO_REG_TOKEN` and `SHARED_BOUNCER_KEY` private.
- Do not expose Web UI port to public internet.
- Restrict LAPI access with explicit `Allowed IP/CIDR`.

## Validation

Use Git Bash or Linux shell:

```bash
bash -n central.sh
bash -n vps.sh
```

On this Windows environment, explicit path may be needed:

```powershell
& "C:\Program Files\Git\bin\bash.exe" -n "/c/Users/user/Documents/скрипты для CrowdSec/central.sh"
& "C:\Program Files\Git\bin\bash.exe" -n "/c/Users/user/Documents/скрипты для CrowdSec/vps.sh"
```

## Contributing

See `CONTRIBUTING.md`.

## License

MIT - see `LICENSE`.
