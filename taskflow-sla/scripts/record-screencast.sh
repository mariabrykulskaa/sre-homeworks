#!/usr/bin/env bash
# Записывает скринкаст из трёх частей и склеивает их в screencast/screencast.mp4
# (1920×1080):
#   1. терминал — scripts/demo.sh intro: что развёрнуто, исходные SLI/SLO/SLA;
#   2. дашборд Grafana, пока scripts/scenario.sh вносит и снимает сбои (~45 мин):
#      кадр раз в 10 с (scripts/capture-dashboard.mjs) — в видео 4 кадра в
#      секунду, то есть ускорение в 40 раз; на плашке внизу — часы, этап и команда;
#   3. терминал — scripts/demo.sh outro: итог по SLO, SLA и алертам.
# Терминал записывает asciinema (настоящие команды и их вывод), agg рендерит
# запись в GIF, ffmpeg перекодирует всё в H.264 и склеивает.
#
# Нужны туннели scripts/port-forward.sh (в отдельном терминале), asciinema 3,
# agg, ffmpeg, jq, node и Google Chrome (brew install asciinema agg ffmpeg jq node).
# Перед записью стоит дать пройти хотя бы часу без сбоев — см. README.
#
# Использование: scripts/record-screencast.sh [--short | --replay]
#   --short  — короткий сценарий (~15 минут, scripts/scenario.sh --short), кадр раз в 5 с.
#   --replay — пересобрать видео из прошлой записи, ничего не внося: терминал — из
#              intro.cast и outro.cast, дашборд — по scenario.log из истории
#              VictoriaMetrics (scripts/replay-dashboard.mjs), кадр на каждые 5 с сценария.
#   Результат: screencast/screencast.mp4; рядом — intro.cast и outro.cast
#   (asciinema play …) и scenario.log — время каждого этапа сценария.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FRAME_INTERVAL=10   # секунд между кадрами дашборда
FRAME_RATE=4        # кадров дашборда в секунду видео
VIDEO_SIZE=1920:1080
SCENARIO_ARGS=()
REPLAY=false
case "${1:-}" in
  "") ;;
  --short) SCENARIO_ARGS=(--short); FRAME_INTERVAL=5 ;;
  --replay) REPLAY=true; FRAME_INTERVAL=5 ;;
  *) echo "Использование: $0 [--short | --replay]" >&2; exit 2 ;;
esac

OUT_DIR="$ROOT/screencast"
if [[ "$REPLAY" == true ]]; then
  require_tools agg ffmpeg kubectl
  for file in intro.cast outro.cast scenario.log; do
    [[ -f "$OUT_DIR/$file" ]] || { echo "Нет $OUT_DIR/$file — сначала запишите скринкаст без --replay" >&2; exit 1; }
  done
else
  require_tools asciinema agg ffmpeg jq kubectl
  require_tunnel "$VM_URL/health" VictoriaMetrics
  require_tunnel "$VMALERT_URL/health" vmalert
fi
require_tunnel "$GRAFANA_URL/api/health" Grafana
export_grafana_credentials
ensure_node_deps

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d -t screencast)"
capture_pid=""
cleanup() {
  if [[ -n "$capture_pid" ]]; then
    touch "$WORK/stop"
    wait "$capture_pid" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 143' TERM

# Все части — одного размера, частоты кадров и кодека: тогда склейка
# (concat) идёт без перекодирования. yuv420p — чтобы MP4 открывался в
# QuickTime и браузерах.
encode() {
  ffmpeg -y -loglevel error "$@" -movflags +faststart -pix_fmt yuv420p -r 10 -c:v libx264 -crf 23
}
FIT="scale=${VIDEO_SIZE}:force_original_aspect_ratio=decrease,pad=${VIDEO_SIZE}:(ow-iw)/2:(oh-ih)/2:color=0x272822,setsar=1"

render_terminal() {
  local part="$1"
  agg --font-family "JetBrains Mono,Menlo" --font-size 18 --theme monokai \
    --idle-time-limit 3 "$OUT_DIR/$part.cast" "$WORK/$part.gif"
  encode -i "$WORK/$part.gif" -vf "$FIT" "$WORK/$part.mp4"
}

record_terminal() {
  local part="$1"
  echo "== Терминал: scripts/demo.sh $part"
  asciinema rec --headless --overwrite --window-size 140x40 --idle-time-limit 3 \
    --command "bash scripts/demo.sh $part" "$OUT_DIR/$part.cast"
  render_terminal "$part"
}

# Все части есть — склеиваем их в один файл.
assemble() {
  printf "file '%s'\n" "$WORK/intro.mp4" "$WORK/dashboard.mp4" "$WORK/outro.mp4" > "$WORK/parts.txt"
  ffmpeg -y -loglevel error -f concat -safe 0 -i "$WORK/parts.txt" -c copy -movflags +faststart \
    "$OUT_DIR/screencast.mp4"
  echo "Скринкаст: $OUT_DIR/screencast.mp4"
  ffprobe -v error -show_entries format=duration -of default=nw=1 "$OUT_DIR/screencast.mp4"
}

# Запуск из корня задания: в demo.sh и scenario.sh пути к скриптам
# относительные, как у человека в терминале.
cd "$ROOT"

if [[ "$REPLAY" == true ]]; then
  echo "== Пересборка из intro.cast, outro.cast и scenario.log (сбои не вносятся)"
  render_terminal intro
  # Время в журнале — местное, без даты; дата — день, когда журнал записан.
  node scripts/replay-dashboard.mjs "$GRAFANA_URL$DASHBOARD_PATH?kiosk" \
    "$OUT_DIR/scenario.log" "$(date -r "$OUT_DIR/scenario.log" +%F)" "$WORK/frames" "$FRAME_INTERVAL"
  encode -framerate "$FRAME_RATE" -i "$WORK/frames/frame-%05d.png" -vf "$FIT" "$WORK/dashboard.mp4"
  render_terminal outro
  assemble
  exit 0
fi

record_terminal intro

echo "== Дашборд Grafana и сценарий сбоев"
dashboard_url="$GRAFANA_URL$DASHBOARD_PATH?kiosk&from=now-30m&to=now"
node scripts/capture-dashboard.mjs \
  "$dashboard_url" "$WORK/frames" "$WORK/caption" "$WORK/stop" "$FRAME_INTERVAL" &
capture_pid=$!
# Сценарий начинаем, когда запись уже идёт: первый кадр — признак того, что
# Chrome запустился и Grafana приняла пароль.
for _ in $(seq 1 90); do
  [[ -f "$WORK/frames/frame-00001.png" ]] && break
  kill -0 "$capture_pid" 2>/dev/null || { echo "Запись дашборда не запустилась" >&2; exit 1; }
  sleep 1
done
[[ -f "$WORK/frames/frame-00001.png" ]] || { echo "Нет первого кадра дашборда за 90 с" >&2; exit 1; }

scripts/scenario.sh ${SCENARIO_ARGS[@]+"${SCENARIO_ARGS[@]}"} "$WORK/caption" 2>&1 | tee "$OUT_DIR/scenario.log"
# Ещё минута записи: последние точки сценария доходят до графиков с задержкой.
sleep 60
touch "$WORK/stop"
if ! wait "$capture_pid"; then
  capture_pid=""
  echo "Запись дашборда прервалась во время сценария (ошибки — выше) — скринкаст не собран" >&2
  exit 1
fi
capture_pid=""
encode -framerate "$FRAME_RATE" -i "$WORK/frames/frame-%05d.png" -vf "$FIT" "$WORK/dashboard.mp4"

record_terminal outro
assemble
