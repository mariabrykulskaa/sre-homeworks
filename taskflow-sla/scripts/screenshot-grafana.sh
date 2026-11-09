#!/usr/bin/env bash
# Скриншот дашборда «TaskFlow — SLI, SLO, SLA» в Grafana (или одной панели).
# Нужен туннель scripts/port-forward.sh; пароль берётся из Secret.
#
# Использование: scripts/screenshot-grafana.sh ФАЙЛ.png [ПАРАМЕТРЫ] [ВЫСОТА]
#   ПАРАМЕТРЫ — query-строка URL дашборда, по умолчанию «kiosk&from=now-1h&to=now»;
#               одна панель — «viewPanel=8&kiosk&from=now-1h&to=now».
#   ВЫСОТА — высота окна, по умолчанию 1080 (ширина — 1920).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "Использование: $0 ФАЙЛ.png [ПАРАМЕТРЫ] [ВЫСОТА]" >&2
  exit 2
fi
OUT="$1"
PARAMS="${2:-kiosk&from=now-1h&to=now}"
HEIGHT="${3:-1080}"

require_tools kubectl
require_tunnel "$GRAFANA_URL/api/health" Grafana
export_grafana_credentials
ensure_node_deps

node "$ROOT/scripts/screenshot-grafana.mjs" \
  "$OUT" "$GRAFANA_URL$DASHBOARD_PATH?$PARAMS" "$HEIGHT"
