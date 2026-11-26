#!/usr/bin/env bash
# ДЗ №8, стратегия 3 — Canary (запись: scripts/record.sh canary).
# Обе версии работают рядом; долю трафика новой версии задают веса backendRefs
# в HTTPRoute: 90/10 → 50/50 → 0/100. На каждом шаге — трафик и итог.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
trap 'stop_gateway_tunnel; stop_log_capture /dev/null' EXIT

set_weights() {
  run "kubectl -n $NS patch httproute taskflow --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/weight\",\"value\":$1},{\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":$2}]'"
}

STEP_STARTS=()
step() {
  run "kubectl -n $NS get httproute taskflow -o $ROUTE_COLUMNS"
  STEP_STARTS+=("$(date -u +%Y-%m-%dT%H:%M:%S.000Z)")
  run "scripts/traffic.sh --duration 12"
}

fresh_strategy canary
ensure_gateway_tunnel
mark_start
start_log_capture strategy=canary

clear_screen
say "Canary: stable ($V1) и canary ($V2) рядом; долю canary задаёт weight в HTTPRoute"
run "kubectl apply -k k8s/strategies/canary"
wait_rollouts taskflow-stable taskflow-canary >/dev/null
run "kubectl -n $NS get pods -l strategy=canary -o $PODS_COLUMNS"
note "Доля не зависит от числа реплик: по 2 пода у каждой версии, а трафик делится 90/10."

say "Шаг 1: 90/10 — новая версия получает 10 % запросов"
step

say "Шаг 2: 50/50 — ошибок нет, увеличиваем долю canary"
set_weights 50 50
step

say "Шаг 3: 0/100 — весь трафик на canary ($V2)"
set_weights 0 100
step

wait_envoy_flush
say "Access-лог Envoy: сколько запросов обслужила каждая версия на каждом шаге"
run "$(envoy_log_cmd) | jq -r --arg s2 ${STEP_STARTS[1]} --arg s3 ${STEP_STARTS[2]} 'select(.authority==\"$GW_HOST\") | (if .start_time < \$s2 then \"шаг 1 (90/10) \" elif .start_time < \$s3 then \"шаг 2 (50/50) \" else \"шаг 3 (0/100) \" end) + .app_version + \" \" + (.response_code|tostring)' | sort | uniq -c"
note "Дальше — продвижение: stable обновляют до $V2 и возвращают ему 100 %, canary удаляют."

save_logs 3-canary
note "Логи сохранены: logs/3-canary.envoy.log, logs/3-canary.app.log"
sleep 2
