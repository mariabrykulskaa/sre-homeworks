#!/usr/bin/env bash
# Пробрасывает на localhost порты Victoria Logs, vmalert и Alertmanager и держит
# туннели, пока не нажать Ctrl+C.
#   vmui:          http://127.0.0.1:9428/select/vmui/
#   vmalert:       http://127.0.0.1:8880/vmalert/
#   Alertmanager:  http://127.0.0.1:9093/
#
# Использование: scripts/port-forward.sh
#   Порты переопределяются переменными VL_LOCAL_PORT, VMALERT_LOCAL_PORT, AM_LOCAL_PORT.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

pids=()
ports=()
# ${arr[@]+"${arr[@]}"} — безопасное раскрытие пустого массива под set -u в bash 3.2 (macOS).
cleanup() { kill ${pids[@]+"${pids[@]}"} 2>/dev/null || true; }
trap cleanup EXIT INT TERM

kubectl -n "$NS_LOG" port-forward svc/victoria-logs "${VL_LOCAL_PORT}:9428" &
pids+=($!); ports+=("$VL_LOCAL_PORT")
kubectl -n "$NS_LOG" port-forward svc/vmalert "${VMALERT_LOCAL_PORT}:8880" &
pids+=($!); ports+=("$VMALERT_LOCAL_PORT")
kubectl -n "$NS_LOG" port-forward svc/alertmanager "${AM_LOCAL_PORT}:9093" &
pids+=($!); ports+=("$AM_LOCAL_PORT")

# Туннель, умерший сразу (обычно — порт занят), иначе остался бы незамеченным до первого запроса.
sleep 1
for i in "${!pids[@]}"; do
  if ! kill -0 "${pids[$i]}" 2>/dev/null; then
    echo "Туннель на порт ${ports[$i]} не поднялся — порт занят? (lsof -nP -iTCP:${ports[$i]})" >&2
    exit 1
  fi
done

echo
echo "Victoria Logs API:  $VL_URL"
echo "vmui:               $VL_URL/select/vmui/"
echo "vmalert:            $VMALERT_URL/vmalert/"
echo "Alertmanager:       $AM_URL/"
echo "(Ctrl+C — закрыть туннели)"
wait
