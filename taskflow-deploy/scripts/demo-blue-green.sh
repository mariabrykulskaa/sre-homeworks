#!/usr/bin/env bash
# ДЗ №8, стратегия 2 — Blue/Green (запись: scripts/record.sh blue-green).
# Обе версии развёрнуты целиком; переключение и откат — одна правка
# backendRefs в HTTPRoute, под постоянным трафиком.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
trap 'stop_gateway_tunnel; stop_log_capture /dev/null' EXIT

route_to() {
  run_now "kubectl -n $NS patch httproute taskflow --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/name\",\"value\":\"taskflow-$1\"}]'"
}

fresh_strategy blue-green
ensure_gateway_tunnel
mark_start
start_log_capture strategy=blue-green

clear_screen
say "Blue/Green: blue ($V1) и green ($V2) работают рядом, пользователи — на blue"
run "kubectl apply -k k8s/strategies/blue-green"
wait_rollouts taskflow-blue taskflow-green >/dev/null
run "kubectl -n $NS get pods -l strategy=blue-green -o $PODS_COLUMNS"
run "kubectl -n $NS get httproute -o $ROUTE_COLUMNS"

say "Пользовательский адрес — blue; green проверяем через тот же шлюз по имени preview.taskflow.local"
run "curl -s -H 'Host: $GW_HOST' $GW_URL/api/version; echo"
run "curl -s -H 'Host: preview.$GW_HOST' $GW_URL/api/version; echo"
run "curl -s -o /dev/null -w 'preview /api/projects → %{http_code}\\n' -H 'Host: preview.$GW_HOST' $GW_URL/api/projects"

say "Трафик 20 запросов/с; переключение на green, затем откат на blue"
printf '%s$ %s%s\n' "$GREEN" "scripts/traffic.sh --duration 32 --pods &" "$RESET"
scripts/traffic.sh --duration 32 --pods &
traffic_pid=$!
sleep 8
printf '%s# переключение: blue → green%s\n' "$BOLD$YELLOW" "$RESET"
route_to green
sleep 12
printf '%s# откат: green → blue (blue не останавливали — откат мгновенный)%s\n' "$BOLD$YELLOW" "$RESET"
route_to blue
wait "$traffic_pid" || true
sleep "$PAUSE"

say "Маршрут снова на blue; green работает и ждёт следующей попытки"
run "kubectl -n $NS get httproute taskflow -o $ROUTE_COLUMNS"
run "kubectl -n $NS get pods -l strategy=blue-green -o $PODS_COLUMNS"

wait_envoy_flush
say "Access-лог Envoy: непрерывные отрезки ответов одной версии (время UTC)"
run "$(envoy_log_cmd) | jq -r 'select(.authority==\"$GW_HOST\") | \"\\(.start_time[11:23]) \\(.app_version) \\(.response_code)\"' | awk '\$2!=v {if (v) print v, n, \"запросов\", t0, \"→\", t1; v=\$2; n=0; t0=\$1} {n++; t1=\$1} END {print v, n, \"запросов\", t0, \"→\", t1}'"
run "$(envoy_log_cmd) | jq -r 'select(.authority==\"$GW_HOST\") | .response_code' | sort | uniq -c"

save_logs 2-blue-green
note "Логи сохранены: logs/2-blue-green.envoy.log, logs/2-blue-green.app.log"
sleep 2
