#!/usr/bin/env bash
# Записывает скринкаст: выполняет scripts/demo.sh под asciinema (настоящий
# терминал, реальные команды и их вывод), рендерит запись в GIF через agg и
# перекодирует в MP4 через ffmpeg.
#
# Использование: scripts/record-screencast.sh
#   Результат: screencast/screencast.mp4 (+ screencast.cast — исходная запись,
#   её можно проиграть `asciinema play screencast/screencast.cast`).
#   Нужны asciinema 3, agg, ffmpeg (brew install asciinema agg ffmpeg).
#   Туннели на 8428/8429 demo.sh поднимает сам — scripts/port-forward.sh
#   на время записи остановите.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

for tool in asciinema agg ffmpeg jq; do
  command -v "$tool" >/dev/null || { echo "Не найден $tool (brew install $tool)" >&2; exit 1; }
done
for port in 8428 8429; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Порт $port занят (остановите scripts/port-forward.sh): demo.sh поднимает туннели сам" >&2
    exit 1
  fi
done

OUT_DIR="$ROOT/screencast"
mkdir -p "$OUT_DIR"
CAST="$OUT_DIR/screencast.cast"
GIF="$(mktemp -t screencast).gif"
trap 'rm -f "$GIF"' EXIT

# Запуск из корня задания: в demo.sh пути к скриптам относительные, как у человека в терминале.
cd "$ROOT"
asciinema rec --headless --overwrite --window-size 140x40 --idle-time-limit 3 \
  --command "bash scripts/demo.sh" "$CAST"

agg --font-family "JetBrains Mono,Menlo" --font-size 16 --theme monokai \
  --idle-time-limit 3 "$CAST" "$GIF"

# yuv420p и чётные размеры кадра — чтобы MP4 открывался в QuickTime и браузерах.
ffmpeg -y -loglevel error -i "$GIF" -movflags +faststart -pix_fmt yuv420p \
  -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' -c:v libx264 -crf 23 "$OUT_DIR/screencast.mp4"

echo "Скринкаст: $OUT_DIR/screencast.mp4"
ffprobe -v error -show_entries format=duration -of default=nw=1 "$OUT_DIR/screencast.mp4"
