#!/usr/bin/env bash
# Делает скриншот vmui с заданным LogsQL-запросом headless-Chrome'ом —
# так получены картинки в screenshots/ для отчёта. Нужен туннель
# (scripts/port-forward.sh) и Google Chrome (путь можно задать в CHROME).
#
# Использование: scripts/screenshot-vmui.sh ФАЙЛ.png 'LOGSQL' [диапазон, напр. 30m] [доп. параметры URL]
#   доп. параметры vmui: view=group|table|json, displayFields=поле1,поле2 (для group),
#   hide_chart=true. Пример: 'view=json&hide_chart=true'
#   Переменные: SHOT_HEIGHT — высота окна в пикселях (по умолчанию 900; для
#   длинных JSON-результатов stats-запросов удобно 1400), CHROME — путь к Chrome.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ $# -lt 2 ]]; then
  echo "Использование: $0 ФАЙЛ.png 'LOGSQL-запрос' [диапазон] [доп. параметры URL]" >&2
  exit 2
fi
OUT="$1"
QUERY="$2"
RANGE="${3:-30m}"
EXTRA="${4:-}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
SHOT_HEIGHT="${SHOT_HEIGHT:-900}"
if ! [[ "$SHOT_HEIGHT" =~ ^[1-9][0-9]*$ ]]; then
  echo "SHOT_HEIGHT: ожидается положительное число, получено «$SHOT_HEIGHT»" >&2
  exit 2
fi

if [[ ! -x "$CHROME" ]]; then
  echo "Chrome не найден: $CHROME (задайте CHROME=путь/к/бинарнику)" >&2
  exit 1
fi

encoded="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$QUERY")"
url="$VL_URL/select/vmui/#/?query=${encoded}&g0.range_input=${RANGE}${EXTRA:+&$EXTRA}"

# virtual-time-budget даёт SPA время выполнить запрос и отрисовать результат.
"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
  --window-size="1440,${SHOT_HEIGHT}" --virtual-time-budget=10000 \
  --screenshot="$OUT" "$url" 2>/dev/null
echo "Скриншот: $OUT"
