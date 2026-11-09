#!/usr/bin/env bash
# Терминальные части скринкаста — до и после сценария сбоев. Команды
# печатаются перед выполнением, как будто их набирают в терминале.
#
#   intro  что развёрнуто: поды, пробер и его метрики, правила vmalert,
#          исходные SLI/SLO/SLA
#   outro  итог после сценария: SLO, SLA и алерты
#
# Запускается под записью: scripts/record-screencast.sh (или вручную).
# Нужны туннели scripts/port-forward.sh.
#
# Использование: scripts/demo.sh intro|outro
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

BOLD=$'\e[1m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; RESET=$'\e[0m'
TYPE_DELAY="${TYPE_DELAY:-0.02}"

say() { printf '\n%s# %s%s\n' "$BOLD$CYAN" "$1" "$RESET"; sleep 0.8; }

# run 'команда' — «набирает» команду посимвольно и выполняет её через bash.
run() {
  local cmd="$1" i
  printf '%s$ %s' "$GREEN" "$RESET"
  for ((i = 0; i < ${#cmd}; i++)); do
    printf '%s' "${cmd:i:1}"
    sleep "$TYPE_DELAY"
  done
  printf '\n'
  bash -o pipefail -c "$cmd" || true
  sleep 1.5
}

intro() {
  say "ДЗ №5: SLI, SLO и SLA для TaskFlow (minikube)"
  run "helm list -n monitoring"
  run "kubectl get pods -n monitoring"
  run "kubectl get pods -n taskflow"

  say "Пробер: сценарии пользователя через Service TaskFlow, раз в 5 секунд"
  run "kubectl logs -n monitoring deploy/taskflow-prober --tail 2"
  run "kubectl exec -n monitoring deploy/taskflow-prober -- python -c \"import urllib.request as u; print(u.urlopen('http://127.0.0.1:9464/metrics').read().decode(), end='')\" | grep -E '^prober_probe_(runs_total|success)'"

  say "vmalert считает SLI, SLO и SLA по правилам k8s/monitoring/rules/slo-rules.yaml"
  run "curl -s $VMALERT_URL/api/v1/rules | jq -r '.data.groups[] | \"\\(.name): \\(.rules | length) правил\"'"
  run "curl -s $VM_URL/api/v1/label/__name__/values | jq -r '.data[] | select(startswith(\"slo:\") or startswith(\"sla:\"))'"

  say "Исходное состояние перед сценарием"
  run "scripts/fault.sh status"
  run "scripts/check-slo.sh"

  say "Дальше — дашборд Grafana, пока scripts/scenario.sh вносит сбои (ускорено)"
  sleep 2
}

outro() {
  say "Итог после сценария"
  run "scripts/fault.sh status"
  run "scripts/check-slo.sh"
  say "Алерты в vmalert"
  run "curl -s $VMALERT_URL/api/v1/alerts | jq -r '.data.alerts[] | \"\\(.state)  \\(.labels.alertname)  slo=\\(.labels.slo)  \\(.annotations.summary)\"'"
  sleep 2
}

case "${1:-}" in
  intro|outro)
    require_tools jq curl
    require_tunnel "$VM_URL/health" VictoriaMetrics
    require_tunnel "$VMALERT_URL/health" vmalert
    # Пути к скриптам в командах — относительные, как у человека в терминале.
    cd "$ROOT"
    clear
    "$1"
    ;;
  *)
    echo "Использование: $0 intro|outro" >&2
    exit 2
    ;;
esac
