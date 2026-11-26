#!/usr/bin/env bash
# Записывает демонстрации стратегий выкатки — видео и логи для каждой:
#   screencast/N-<стратегия>.mp4    — видео терминала, 1920×1080
#   screencast/N-<стратегия>.cast   — исходная запись asciinema (можно проиграть: asciinema play)
#   logs/N-<стратегия>.terminal.log — текст всего, что было на экране
#   logs/N-<стратегия>.envoy.log    — access-лог Envoy за демонстрацию (JSON)
#   logs/N-<стратегия>.app.log      — логи всех подов приложения за демонстрацию (JSON)
#   screencast/all-strategies.mp4   — все пять видео подряд
# Команды в записи настоящие, вывод живой; asciinema записывает терминал, agg
# рендерит запись в GIF, ffmpeg приводит его к MP4.
#
# Нужны: minikube со стендом (scripts/install-envoy-gateway.sh,
# scripts/build-images.sh, scripts/deploy-platform.sh), asciinema 3, agg, ffmpeg, jq
# (brew install asciinema agg ffmpeg jq).
#
# Использование: scripts/record.sh [стратегия…]   (по умолчанию — все пять)
#   стратегии: rolling blue-green canary ab-testing shadow
#   RENDER_ONLY=1 scripts/record.sh … — только перерендерить видео из готовых .cast
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

for tool in asciinema agg ffmpeg jq kubectl python3; do
  command -v "$tool" >/dev/null || { echo "Не найден $tool" >&2; exit 1; }
done

ALL="1-rolling 2-blue-green 3-canary 4-ab-testing 5-shadow"
script_of() {
  case "$1" in
    *-rolling) echo demo-rolling.sh ;;
    *-blue-green) echo demo-blue-green.sh ;;
    *-canary) echo demo-canary.sh ;;
    *-ab-testing) echo demo-ab.sh ;;
    *-shadow) echo demo-shadow.sh ;;
  esac
}

selected=()
if [[ $# -eq 0 ]]; then
  read -r -a selected <<<"$ALL"
else
  for want in "$@"; do
    for name in $ALL; do
      [[ "$name" == *"-$want" ]] && selected+=("$name")
    done
  done
fi
[[ ${#selected[@]} -gt 0 ]] || { echo "Неизвестная стратегия: $*" >&2; exit 1; }

mkdir -p screencast logs
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Кадр 1920×1080, 25 кадров/с; терминал — по центру на фоне темы monokai.
fit='scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0x272822,fps=25,format=yuv420p'
export TERM="${TERM:-xterm-256color}"

# Узел и API-сервер отвечают — иначе запись начнётся с ошибок kubectl.
wait_cluster_ready() {
  local i
  for i in $(seq 1 90); do
    if kubectl get --raw=/readyz >/dev/null 2>&1 &&
      ! kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
        grep -qv True; then
      return 0
    fi
    sleep 2
  done
  echo "Кластер не готов — запись отменена" >&2
  return 1
}

# 1. Запись. Видео рендерится потом: agg и ffmpeg занимают все ядра хоста, и
#    если рендерить между записями, виртуальной машине Docker (а с ней kubelet и
#    container runtime в minikube) не хватает CPU — узел на минуты уходит в NotReady.
#    RENDER_ONLY=1 — пропустить запись и заново отрендерить готовые .cast.
for name in "${selected[@]}"; do
  [[ "${RENDER_ONLY:-}" == 1 ]] && break
  demo="$(script_of "$name")"
  echo "=== запись $name ($demo)"
  wait_cluster_ready
  asciinema rec --headless --overwrite --window-size 140x42 --idle-time-limit 2 \
    --command "bash scripts/$demo" "screencast/$name.cast"
  asciinema convert -f txt --overwrite "screencast/$name.cast" "logs/$name.terminal.log"
done

# 2. Рендер — с пониженным приоритетом и ограничением потоков ffmpeg.
for name in "${selected[@]}"; do
  echo "=== видео $name"
  nice -n 15 agg --font-family "JetBrains Mono,Menlo" --font-size 18 --theme monokai \
    --idle-time-limit 2 --last-frame-duration 5 "screencast/$name.cast" "$WORK/$name.gif"
  nice -n 15 ffmpeg -y -loglevel error -i "$WORK/$name.gif" -vf "$fit" -c:v libx264 -crf 23 \
    -preset veryfast -threads 2 -movflags +faststart "screencast/$name.mp4"
  printf '%s: %s с видео\n' "screencast/$name.mp4" \
    "$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "screencast/$name.mp4" | cut -d. -f1)"
done

# Общее видео — пять записей подряд (одинаковые параметры кодирования, без перекодирования).
list="$WORK/list.txt"
: >"$list"
for name in $ALL; do
  [[ -f "screencast/$name.mp4" ]] && printf "file '%s'\n" "$ROOT/screencast/$name.mp4" >>"$list"
done
ffmpeg -y -loglevel error -f concat -safe 0 -i "$list" -c copy -movflags +faststart screencast/all-strategies.mp4
echo "Общее видео: screencast/all-strategies.mp4 ($(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 screencast/all-strategies.mp4 | cut -d. -f1) с)"
ls -la screencast logs
