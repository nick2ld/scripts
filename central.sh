#!/usr/bin/env bash
set -Eeuo pipefail

URL="https://raw.githubusercontent.com/nick2ld/scripts/main/crowdsec/central.sh"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL -H "Cache-Control: no-cache" "${URL}?$(date +%s)" -o "$tmp"
bash "$tmp" "$@"
