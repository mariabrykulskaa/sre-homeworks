#!/usr/bin/env bash
# ДЗ №8, стратегия 5 — Shadow / зеркалирование (запись: scripts/record.sh shadow).
# Пользователям отвечает primary; Envoy копирует каждый GET в shadow и
# отбрасывает её ответ. Показано: копии доходят до shadow (тот же request_id),
# изменяющие запросы не дублируются, ошибки shadow не видны пользователям.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
trap 'stop_gateway_tunnel; stop_log_capture /dev/null' EXIT

# Логи приложения дорожки (primary | shadow) с момента $2 — только запросы к API.
api_log() {
  printf 'kubectl -n %s logs -l track=%s -c taskflow --tail=-1 --since-time=%s | jq -c '"'"'select(.message=="request" and (.path|startswith("/api/")) and (.path|test("health|ready")|not))'"'"'' \
    "$NS" "$1" "$2"
}

fresh_strategy shadow
ensure_gateway_tunnel
mark_start
start_log_capture strategy=shadow

clear_screen
say "Shadow: отвечает primary ($V1), копии GET-запросов уходят в shadow ($V2)"
run "kubectl apply -k k8s/strategies/shadow"
wait_rollouts taskflow-primary taskflow-shadow >/dev/null
run "kubectl -n $NS get pods -l strategy=shadow -o $PODS_COLUMNS"
run "kubectl -n $NS get httproute taskflow -o jsonpath='{range .spec.rules[*]}method={.matches[0].method}  filters={.filters[*].requestMirror.backendRef.name}  →  {.backendRefs[0].name}{\"\\n\"}{end}'"

say "200 GET-запросов: клиенты видят только $V1"
t1="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run "scripts/traffic.sh --requests 200 --quiet"

say "…а shadow получила копии тех же запросов: столько же, с тем же Host"
run "$(api_log primary "$t1") | jq -r '\"\\(.\"service.version\") host=\\(.host)\"' | sort | uniq -c"
run "$(api_log shadow "$t1") | jq -r '\"\\(.\"service.version\") host=\\(.host)\"' | sort | uniq -c"
run "rid=\$($(api_log shadow "$t1") | jq -r .request_id | tail -1); for t in primary shadow; do $(api_log '$t' "$t1") | jq -c --arg r \"\$rid\" 'select(.request_id==\$r) | {version: .\"service.version\", host, method, path, status, request_id}'; done"
note "Один request_id в обеих версиях: оригинал и его копия (Envoy Gateway не меняет Host копии — disable_shadow_host_suffix_append)."

say "Изменяющие запросы не зеркалируются: копия POST создала бы второй проект в общей базе"
t2="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
name="shadow-demo-$(date -u +%H%M%S)"
run "curl -s -o /dev/null -w 'POST /api/projects → %{http_code}, версия %header{x-app-version}\\n' -X POST -H 'Host: $GW_HOST' -H 'Content-Type: application/json' -d '{\"name\":\"$name\"}' $GW_URL/api/projects"
run "for t in primary shadow; do printf '%-8s POST: ' \$t; $(api_log '$t' "$t2") | jq -c 'select(.method==\"POST\")' | wc -l; done"
run "curl -s -H 'Host: $GW_HOST' '$GW_URL/api/projects?limit=100' | jq '[.data[] | select(.name==\"$name\")] | length'"

say "Ошибки новой версии не видны пользователям: включаем в shadow 50 % сбоев"
run "kubectl -n $NS set env deploy/taskflow-shadow FAULT_ERROR_RATE=0.5"
run "kubectl -n $NS rollout status deploy/taskflow-shadow --timeout=180s"
t3="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run "scripts/traffic.sh --requests 200 --quiet"
run "$(api_log shadow "$t3") | jq -r '\"shadow \\(.\"service.version\") → \\(.status)\"' | sort | uniq -c"
note "Shadow отвечает 500 на половину копий, а клиенты получили 0 ошибок: ответы копий Envoy отбрасывает."

wait_envoy_flush
say "Access-лог Envoy: все ответы клиентам — от $V1 (копии в журнал запросов не попадают)"
run "$(envoy_log_cmd) | jq -r 'select(.authority==\"$GW_HOST\") | \"\\(.method) \\(.app_version) \\(.response_code)\"' | sort | uniq -c"

save_logs 5-shadow
note "Логи сохранены: logs/5-shadow.envoy.log, logs/5-shadow.app.log"
sleep 2
