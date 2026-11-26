#!/usr/bin/env bash
# ДЗ №8, стратегия 1 — Rolling update (запись: scripts/record.sh rolling).
# Один Deployment из 4 реплик; новая версия выкатывается заменой подов по
# одному под постоянным трафиком через Envoy Gateway.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
trap 'stop_gateway_tunnel; stop_log_capture /dev/null' EXIT

fresh_strategy rolling
ensure_gateway_tunnel
mark_start
start_log_capture strategy=rolling

clear_screen
say "Rolling update: один Deployment, поды заменяются по одному (maxSurge 1, maxUnavailable 0)"
run "kubectl -n $NS get gateway eg"
run "kubectl apply -k k8s/strategies/rolling"
run "kubectl -n $NS rollout status deploy/taskflow --timeout=180s"
run "kubectl -n $NS get pods -l strategy=rolling -o $PODS_COLUMNS_NO_TRACK"
run "kubectl -n $NS get deploy taskflow -o jsonpath='{.spec.strategy}  minReadySeconds={.spec.minReadySeconds}{\"\\n\"}'"

say "Через шлюз отвечает $V1 — версия в теле /api/version и в заголовке X-App-Version"
run "curl -s -H 'Host: $GW_HOST' $GW_URL/api/version; echo"
run "curl -s -o /dev/null -D - -H 'Host: $GW_HOST' $GW_URL/api/projects | grep -i -E '^x-(app-version|served-by)'"

say "Постоянный трафик 20 запросов/с; в строке — ответы по версиям за секунду и [число реплик]"
printf '%s$ %s%s\n' "$GREEN" "scripts/traffic.sh --duration 75 --pods &" "$RESET"
scripts/traffic.sh --duration 75 --pods &
traffic_pid=$!
sleep 6
run_now "kubectl -n $NS set image deploy/taskflow migrate=$IMAGE:$V2 taskflow=$IMAGE:$V2"
run_now "kubectl -n $NS annotate deploy/taskflow kubernetes.io/change-cause='release $V2' --overwrite"
run_now "kubectl -n $NS rollout status deploy/taskflow --timeout=180s"
wait "$traffic_pid" || true
sleep "$PAUSE"

say "Итог: все реплики — $V2, история ревизий позволяет откатиться (kubectl rollout undo)"
run "kubectl -n $NS get pods -l strategy=rolling -o $PODS_COLUMNS_NO_TRACK"
run "kubectl -n $NS get rs -l strategy=rolling -o wide | cut -c1-120"
run "kubectl -n $NS rollout history deploy/taskflow"

say "Версия в метрике: taskflow_build_info на порту /metrics (9464) реплики"
run "kubectl -n $NS exec deploy/taskflow -c taskflow -- python -c \"import urllib.request as u; print(*[l for l in u.urlopen('http://127.0.0.1:9464/metrics').read().decode().splitlines() if l.startswith('taskflow_build')], sep='\\n')\""

wait_envoy_flush
say "Access-лог Envoy за демонстрацию: ответы по версиям и кодам"
run "$(envoy_log_cmd) | jq -r '\"\\(.app_version) \\(.response_code)\"' | sort | uniq -c"

save_logs 1-rolling
note "Логи сохранены: logs/1-rolling.envoy.log (Envoy), logs/1-rolling.app.log (все поды, включая удалённые)"
sleep 2
