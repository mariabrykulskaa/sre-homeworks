#!/usr/bin/env bash
# Записывает скринкаст ДЗ №2 в screencast/screencast.mp4 (1920×1080) из двух частей:
#   1. терминал — scripts/demo.sh: kubectl apply, вывод подов, масштабирование;
#      asciinema записывает настоящие команды и их вывод, agg рендерит запись;
#   2. браузер — scripts/ui-demo.mjs: клики в UI приложения, запущенного в minikube
#      (через kubectl port-forward); Playwright записывает видео окна.
# ffmpeg приводит обе части к 1920×1080 и склеивает.
#
# Нужны minikube с образом taskflow:2.0, asciinema 3, agg, ffmpeg, node и Google Chrome
# (brew install asciinema agg ffmpeg node; npm ci --prefix scripts).
#
# Использование: scripts/record-screencast.sh [--fresh]
#   --fresh — перед записью удалить namespace taskflow и данные БД, чтобы `kubectl apply`
#             в записи поднимал всё с нуля. Данные удаляются и с диска узла: hostPath-провижинер
#             minikube при удалении PVC папку не стирает, и новый PVC с тем же именем получил бы
#             старую базу.
# Если в кластере работает пробер из ДЗ №5, на время записи он останавливается — иначе
# его синтетические проекты мелькали бы в UI.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

for tool in asciinema agg ffmpeg node kubectl; do
  command -v "$tool" >/dev/null || { echo "Не найден $tool" >&2; exit 1; }
done
if [[ ! -d "$ROOT/scripts/node_modules/playwright-core" ]]; then
  npm ci --prefix "$ROOT/scripts" --ignore-scripts --no-audit --no-fund
fi

if [[ "${1:-}" == --fresh ]]; then
  kubectl delete namespace "$NS" --ignore-not-found --wait=true
  minikube ssh -- "sudo rm -rf /tmp/hostpath-provisioner/$NS"
fi

prober_replicas="$(kubectl -n monitoring get deploy taskflow-prober -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
if [[ -n "$prober_replicas" && "$prober_replicas" != 0 ]]; then
  kubectl -n monitoring scale deploy/taskflow-prober --replicas=0
fi
restore_prober() {
  if [[ -n "$prober_replicas" && "$prober_replicas" != 0 ]]; then
    kubectl -n monitoring scale deploy/taskflow-prober --replicas="$prober_replicas" >/dev/null
  fi
}

OUT_DIR="$ROOT/screencast"
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; kill "${pf_pid:-}" 2>/dev/null || true; restore_prober' EXIT

# 1. Терминал.
export TERM="${TERM:-xterm-256color}"
asciinema rec --headless --overwrite --window-size 120x34 --idle-time-limit 3 \
  --command "bash scripts/demo.sh" "$OUT_DIR/terminal.cast"
agg --font-family "JetBrains Mono,Menlo" --font-size 18 --theme monokai \
  --idle-time-limit 3 "$OUT_DIR/terminal.cast" "$WORK/terminal.gif"

# 2. Браузер — через туннель до Service, как в README.
kubectl -n "$NS" port-forward svc/taskflow 8080:80 >/dev/null 2>&1 &
pf_pid=$!
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null http://127.0.0.1:8080/api/ready 2>/dev/null && break
  sleep 1
done
video="$(node "$ROOT/scripts/ui-demo.mjs" http://127.0.0.1:8080/ "$WORK/video" | tail -1)"

# 3. Склейка: обе части — 1920×1080, 25 кадров/с.
fit='scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0x272822,fps=25,format=yuv420p'
ffmpeg -y -loglevel error -i "$WORK/terminal.gif" -vf "$fit" -c:v libx264 -crf 23 "$WORK/part1.mp4"
# Headless Chrome в режиме записи видео не дорисовывает нижние ~88 px окна (серая
# полоса) — обрезаем их до приведения к 1920×1080.
ffmpeg -y -loglevel error -i "$video" -vf "crop=iw:ih-88:0:0,$fit" -c:v libx264 -crf 23 "$WORK/part2.mp4"
printf "file '%s'\nfile '%s'\n" "$WORK/part1.mp4" "$WORK/part2.mp4" > "$WORK/list.txt"
ffmpeg -y -loglevel error -f concat -safe 0 -i "$WORK/list.txt" -c copy -movflags +faststart \
  "$OUT_DIR/screencast.mp4"

echo "Скринкаст: $OUT_DIR/screencast.mp4"
ffprobe -v error -show_entries format=duration -of default=nw=1 "$OUT_DIR/screencast.mp4"
