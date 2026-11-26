#!/usr/bin/env bash
# Трафик через шлюз с параметрами стенда (адрес туннеля, Host, версии).
# Все аргументы передаются в scripts/traffic.py, например:
#   scripts/traffic.sh --duration 30 --pods
#   scripts/traffic.sh --requests 200 --quiet -H 'X-User-Group: beta'
# Туннель до шлюза поднимается сам, если ещё не поднят.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

trap stop_gateway_tunnel EXIT
ensure_gateway_tunnel
traffic "$@"
