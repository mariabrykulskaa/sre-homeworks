#!/usr/bin/env bash
# Сценарий скринкаста: поды и сервисы VictoriaMetrics, port-forward, проверка
# сбора метрик командами из задания и запросы к метрикам приложения и Postgres.
# Команды печатаются перед выполнением, как будто их набирают в терминале.
#
# Запускается под записью: scripts/record-screencast.sh (или вручную — просто
# выполнить в терминале). Сам поднимает и закрывает туннели.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

BOLD=$'\e[1m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; DIM=$'\e[2m'; RESET=$'\e[0m'
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
  sleep 1.2
}

# Текущее значение sum(taskflow_projects_deleted_total) в VictoriaMetrics.
projects_deleted() {
  curl -fsS --get http://localhost:8428/api/v1/query \
    --data-urlencode 'query=sum(taskflow_projects_deleted_total)' | jq -r '.data.result[0].value[1] // "0"'
}

pf_pids=()
cleanup() { kill ${pf_pids[@]+"${pf_pids[@]}"} 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Под записью окно терминала — 140×40 (record-screencast.sh): таблицы kubectl и helm не переносятся.
clear

say "ДЗ №4: метрики TaskFlow в VictoriaMetrics (minikube)"
run "helm list -n monitoring"

say "Поды и сервисы Victoria Metrics"
run "kubectl get pods -n monitoring"
run "kubectl get svc -n monitoring"

say "Приложение: 2 реплики TaskFlow, в поде БД — PostgreSQL + postgres-exporter (2/2)"
run "kubectl get pods -n taskflow"

say "Проброс портов к VictoriaMetrics (8428) и vmagent (8429)"
printf '%s$ %s%s\n' "$GREEN" "$RESET" \
  "kubectl port-forward svc/$VM_SINGLE_SVC -n monitoring 8428:8428 &"
kubectl port-forward "svc/$VM_SINGLE_SVC" -n "$NS_MON" 8428:8428 >/dev/null 2>&1 &
pf_pids+=($!)
printf '%s$ %s%s\n' "$GREEN" "$RESET" \
  "kubectl port-forward svc/$VM_AGENT_SVC -n monitoring 8429:8429 &"
kubectl port-forward "svc/$VM_AGENT_SVC" -n "$NS_MON" 8429:8429 >/dev/null 2>&1 &
pf_pids+=($!)
for _ in $(seq 1 20); do
  curl -fsS -o /dev/null http://localhost:8428/health 2>/dev/null \
    && curl -fsS -o /dev/null http://localhost:8429/health 2>/dev/null && break
  sleep 0.5
done
printf '%sтуннели подняты%s\n' "$DIM" "$RESET"
sleep 1

say "Метрики самого приложения: отдельный порт 9464, формат OpenMetrics (наружу не опубликован)"
run "kubectl exec -n taskflow deploy/taskflow -c taskflow -- python -c \"import urllib.request as u; print('Content-Type:', u.urlopen('http://127.0.0.1:9464/metrics').headers['Content-Type'])\""
run "kubectl exec -n taskflow deploy/taskflow -c taskflow -- python -c \"import urllib.request as u; print(u.urlopen('http://127.0.0.1:9464/metrics').read().decode(), end='')\" | grep -E '^# TYPE taskflow_tasks_created|^taskflow_tasks_created|^process_resident_memory|^python_info|^# EOF'"

say "Таргеты, найденные vmagent через service discovery (аннотации prometheus.io/*)"
run "curl -s http://localhost:8429/targets | sed -E 's/ labels=\\{[^}]*\\},//; s/, (scrapes_total|scrape_response_size|samples_scraped|error)=[^,]*//g'"

say "Статус скрейпинга по метрикам vmagent"
run "curl -s http://localhost:8429/metrics | grep -E '^vm_promscrape_(targets\\{type=\"kubernetes_sd_configs\"|scrapes_total|scrapes_failed_total)'"

say "Доступные метрики в VictoriaMetrics: сколько имён и какие от приложения и Postgres"
run "curl -s http://localhost:8428/api/v1/label/__name__/values | jq '.data | length'"
run "curl -s http://localhost:8428/api/v1/label/__name__/values | jq -r '.data[]' | grep -E '^(taskflow_|http_request)'"
run "curl -s http://localhost:8428/api/v1/label/__name__/values | jq -r '.data[]' | grep -cE '^pg_'"

say "up: все таргеты собираются"
run "curl -s 'http://localhost:8428/api/v1/query?query=up' | jq -r '.data.result[] | \"\\(.value[1])  \\(.metric.job)  \\(.metric.pod)\"'"

say "Добавим трафик: проекты, задачи, переходы статусов"
# Последний запрос трафика — удаление проекта в 3-м раунде. Когда его счётчик
# вырос, в хранилище видно всё, что было до него (трафик идёт в одну реплику).
deleted_before="$(projects_deleted)"
run "scripts/generate-traffic.sh --rounds 3 2>&1 | tail -3"
# Метрика видна в запросах после скрейпа (раз в 15 с) и ещё 30 с: VictoriaMetrics
# не отдаёт точки моложе -search.latencyOffset. Ждём по факту, а не наугад.
printf '%sждём, пока vmagent заберёт метрики и они станут видны в запросах (до ~45 с)...%s\n' "$DIM" "$RESET"
for _ in $(seq 1 60); do
  (( $(projects_deleted) > deleted_before )) && break
  sleep 2
done

say "Бизнес-метрики TaskFlow"
run "scripts/check-metrics.sh business"

say "Рантайм Python и HTTP"
run "scripts/check-metrics.sh runtime"
run "scripts/check-metrics.sh http"

say "PostgreSQL через postgres-exporter"
run "scripts/check-metrics.sh postgres"

say "Готово: VictoriaMetrics развёрнута, метрики приложения, рантайма и Postgres собираются"
sleep 2
