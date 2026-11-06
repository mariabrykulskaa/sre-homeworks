#!/usr/bin/env bash
# Скриншот произвольной страницы headless-Chrome'ом (UI vmalert, Alertmanager).
# Для vmui с LogsQL-запросом удобнее scripts/screenshot-vmui.sh — он собирает URL сам.
#
# Использование: scripts/screenshot-url.sh ФАЙЛ.png URL
#   SHOT_HEIGHT — высота окна (по умолчанию 900), CHROME — путь к бинарнику Chrome.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Использование: $0 ФАЙЛ.png URL" >&2
  exit 2
fi
OUT="$1"
URL="$2"
SHOT_HEIGHT="${SHOT_HEIGHT:-900}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if ! [[ "$SHOT_HEIGHT" =~ ^[1-9][0-9]*$ ]]; then
  echo "SHOT_HEIGHT: ожидается положительное число, получено «$SHOT_HEIGHT»" >&2
  exit 2
fi
if [[ ! -x "$CHROME" ]]; then
  echo "Chrome не найден: $CHROME (задайте CHROME=путь/к/бинарнику)" >&2
  exit 1
fi

# virtual-time-budget даёт странице время выполнить запросы и отрисоваться.
"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
  --window-size="1440,${SHOT_HEIGHT}" --virtual-time-budget=10000 \
  --screenshot="$OUT" "$URL" 2>/dev/null
echo "Скриншот: $OUT"
