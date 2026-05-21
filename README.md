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

### 1) Central server

```bash
sudo bash central.sh
```

After installation, interactive menu:

```bash
sudo crowdsec-central-menu --menu
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
