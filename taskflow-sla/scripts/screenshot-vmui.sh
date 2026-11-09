#!/usr/bin/env bash
# Скриншот vmui (VictoriaMetrics UI) с MetricsQL-запросом — так сделаны
# графики в отчёте. Нужен туннель scripts/port-forward.sh.
#
# Использование: scripts/screenshot-vmui.sh ФАЙЛ.png 'ЗАПРОС' [ДИАПАЗОН] [ВИД]
#   ДИАПАЗОН — окно графика (по умолчанию 15m), ВИД — graph | table (по умолчанию graph).
#   SHOT_HEIGHT — высота окна (по умолчанию 1000).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ $# -lt 2 ]]; then
  echo "Использование: $0 ФАЙЛ.png 'ЗАПРОС' [ДИАПАЗОН] [graph|table]" >&2
  exit 2
fi
OUT="$1"
QUERY="$2"
RANGE="${3:-15m}"
case "${4:-graph}" in
  graph) TAB=0 ;;
  table) TAB=1 ;;
  *) echo "ВИД: graph или table, получено «$4»" >&2; exit 2 ;;
esac

# Параметры vmui в hash-URL: g0.expr — запрос, g0.range_input — окно,
# g0.tab — вид (0 — график, 1 — таблица).
expr="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$QUERY")"
SHOT_HEIGHT="${SHOT_HEIGHT:-1000}" "$(dirname "$0")/screenshot-url.sh" "$OUT" \
  "$VM_URL/vmui/#/?g0.expr=${expr}&g0.range_input=${RANGE}&g0.tab=${TAB}"
