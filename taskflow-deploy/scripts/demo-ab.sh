#!/usr/bin/env bash
# ДЗ №8, стратегия 4 — A/B по заголовку (запись: scripts/record.sh ab-testing).
# Аудитория с заголовком X-User-Group: beta получает вариант B (новая версия),
# все остальные — A. Две аудитории шлют трафик одновременно.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
trap 'stop_gateway_tunnel; stop_log_capture /dev/null' EXIT

fresh_strategy ab-testing
ensure_gateway_tunnel
mark_start
start_log_capture strategy=ab-testing

clear_screen
say "A/B: вариант A ($V1) — всем, вариант B ($V2) — аудитории с заголовком X-User-Group: beta"
run "kubectl apply -k k8s/strategies/ab-testing"
wait_rollouts taskflow-a taskflow-b >/dev/null
run "kubectl -n $NS get pods -l strategy=ab-testing -o $PODS_COLUMNS"
run "kubectl -n $NS get httproute taskflow -o jsonpath='{range .spec.rules[*]}match={.matches[0].headers}  →  {.backendRefs[0].name}{\"\\n\"}{end}'"

say "Один и тот же запрос — разные варианты в зависимости от аудитории"
run "curl -s -H 'Host: $GW_HOST' $GW_URL/api/version; echo"
run "curl -s -H 'Host: $GW_HOST' -H 'X-User-Group: beta' $GW_URL/api/version; echo"
run "curl -s -H 'Host: $GW_HOST' -H 'X-User-Group: staff' $GW_URL/api/version; echo"
note "Другое значение заголовка (staff) — не beta: вариант A."

say "Две аудитории одновременно, по 10 запросов/с: «все» и «beta»"
printf '%s$ %s%s\n' "$GREEN" "scripts/traffic.sh --duration 12 --rps 10 --label 'все ' &" "$RESET"
printf '%s$ %s%s\n' "$GREEN" "scripts/traffic.sh --duration 12 --rps 10 --label 'beta' -H 'X-User-Group: beta' &" "$RESET"
scripts/traffic.sh --duration 12 --rps 10 --label 'все ' &
all_pid=$!
scripts/traffic.sh --duration 12 --rps 10 --label 'beta' -H 'X-User-Group: beta' &
beta_pid=$!
wait "$all_pid" "$beta_pid" || true
sleep "$PAUSE"

wait_envoy_flush
say "Access-лог Envoy: аудитория (X-User-Group) → версия, код ответа"
run "$(envoy_log_cmd) | jq -r 'select(.authority==\"$GW_HOST\") | \"\\(.user_group // \"(нет)\") → \\(.app_version) \\(.response_code)\"' | sort | uniq -c"
run "$(envoy_log_cmd) | jq -r 'select(.authority==\"$GW_HOST\") | .route_name' | sort | uniq -c"

save_logs 4-ab-testing
note "Логи сохранены: logs/4-ab-testing.envoy.log, logs/4-ab-testing.app.log"
sleep 2
