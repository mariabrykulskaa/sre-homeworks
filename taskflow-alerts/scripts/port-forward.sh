#!/usr/bin/env bash
# Пробрасывает на localhost порты мониторинга и держит туннели, пока не нажать Ctrl+C.
#   VictoriaMetrics: http://127.0.0.1:8428/vmui/       (API: /api/v1/query)
#   vmagent:         http://127.0.0.1:8429/targets     (состояние скрейпа)
#   vmalert:         http://127.0.0.1:8880/vmalert/    (группы правил, алерты)
#   Grafana:         http://127.0.0.1:3000/            (дашборд «TaskFlow — SLI, SLO, SLA»)
#
# Использование: scripts/port-forward.sh
#   Порты переопределяются переменными VM_LOCAL_PORT, VMAGENT_LOCAL_PORT,
#   VMALERT_LOCAL_PORT, GRAFANA_LOCAL_PORT.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

pids=()
ports=()
# ${arr[@]+"${arr[@]}"} — безопасное раскрытие пустого массива под set -u в bash 3.2 (macOS).
cleanup() { kill ${pids[@]+"${pids[@]}"} 2>/dev/null || true; }
# Ctrl+C и SIGTERM — штатный выход: иначе цикл ниже принял бы закрытые
# туннели за упавшие.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

forward() {
  kubectl -n "$NS_MON" port-forward "svc/$1" "$2:$3" >/dev/null &
  pids+=($!); ports+=("$2")
}
forward "$VM_SINGLE_SVC" "$VM_LOCAL_PORT" 8428
forward "$VM_AGENT_SVC" "$VMAGENT_LOCAL_PORT" 8429
forward "$VMALERT_SVC" "$VMALERT_LOCAL_PORT" 8880
forward "$GRAFANA_SVC" "$GRAFANA_LOCAL_PORT" 80
forward "$ALERTMANAGER_SVC" "$ALERTMANAGER_LOCAL_PORT" 9093
forward "$MAILPIT_SVC" "$MAILPIT_LOCAL_PORT" 8025

# Туннель, умерший сразу (обычно — порт занят), иначе остался бы незамеченным до первого запроса.
sleep 1
for i in "${!pids[@]}"; do
  if ! kill -0 "${pids[$i]}" 2>/dev/null; then
    echo "Туннель на порт ${ports[$i]} не поднялся — порт занят? (lsof -nP -iTCP:${ports[$i]})" >&2
    exit 1
  fi
done

echo "VictoriaMetrics:  $VM_URL/vmui/"
echo "vmagent targets:  $VMAGENT_URL/targets"
echo "vmalert:          $VMALERT_URL/vmalert/groups"
echo "Grafana:          $GRAFANA_URL/d/taskflow-slo   (admin, пароль — scripts/grafana-password.sh)"
echo "vmalert алерты:   $VMALERT_URL/vmalert/alerts"
echo "Alertmanager:     $ALERTMANAGER_URL/#/alerts"
echo "Mailpit (почта):  $MAILPIT_URL/"
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
