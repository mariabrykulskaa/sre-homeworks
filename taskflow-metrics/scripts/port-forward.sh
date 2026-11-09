#!/usr/bin/env bash
# Пробрасывает на localhost порты VictoriaMetrics и vmagent и держит туннели,
# пока не нажать Ctrl+C.
#   VictoriaMetrics: http://127.0.0.1:8428/vmui/      (API: /api/v1/query, /api/v1/label/__name__/values)
#   vmagent:         http://127.0.0.1:8429/targets    (состояние скрейпа; /metrics — метрики самого vmagent)
#
# Использование: scripts/port-forward.sh
#   Порты переопределяются переменными VM_LOCAL_PORT, VMAGENT_LOCAL_PORT.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

pids=()
ports=()
# ${arr[@]+"${arr[@]}"} — безопасное раскрытие пустого массива под set -u в bash 3.2 (macOS).
cleanup() { kill ${pids[@]+"${pids[@]}"} 2>/dev/null || true; }
trap cleanup EXIT INT TERM

kubectl -n "$NS_MON" port-forward "svc/$VM_SINGLE_SVC" "${VM_LOCAL_PORT}:8428" &
pids+=($!); ports+=("$VM_LOCAL_PORT")
kubectl -n "$NS_MON" port-forward "svc/$VM_AGENT_SVC" "${VMAGENT_LOCAL_PORT}:8429" &
pids+=($!); ports+=("$VMAGENT_LOCAL_PORT")

# Туннель, умерший сразу (обычно — порт занят), иначе остался бы незамеченным до первого запроса.
sleep 1
for i in "${!pids[@]}"; do
  if ! kill -0 "${pids[$i]}" 2>/dev/null; then
    echo "Туннель на порт ${ports[$i]} не поднялся — порт занят? (lsof -nP -iTCP:${ports[$i]})" >&2
    exit 1
  fi
done

echo
echo "VictoriaMetrics API:  $VM_URL"
echo "vmui:                 $VM_URL/vmui/"
echo "vmagent targets:      $VMAGENT_URL/targets"
echo "(Ctrl+C — закрыть туннели)"

# Туннель умирает, например, при пересоздании пода за Service. `wait -n` в
# bash 3.2 (macOS) нет, поэтому проверяем процессы сами и выходим, а не
# продолжаем молча работать с мёртвым портом.
while true; do
  for i in "${!pids[@]}"; do
    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
      echo "Туннель на порт ${ports[$i]} закрылся — перезапустите scripts/port-forward.sh" >&2
      exit 1
    fi
  done
  sleep 2
done
