#!/usr/bin/env bash
set -Eeuo pipefail

URL="https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/vps.sh"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL -H "Cache-Control: no-cache" "${URL}?$(date +%s)" -o "$tmp"
bash "$tmp" "$@"
