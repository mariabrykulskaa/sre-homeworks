#!/usr/bin/env bash
# Проверяет, что все метрики доезжают до VictoriaMetrics: состояние таргетов
# vmagent, `up`, метрики рантайма Python и HTTP, бизнес-метрики TaskFlow и
# метрики PostgreSQL. Те же запросы, что в отчёте.
#
# Нужны туннели: scripts/port-forward.sh (в отдельном терминале).
#
# Использование: scripts/check-metrics.sh [раздел]
#   раздел: targets | up | runtime | http | business | postgres | all (по умолчанию all)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

SECTION="${1:-all}"
case "$SECTION" in
  targets|up|runtime|http|business|postgres|all) ;;
  *) echo "Неизвестный раздел: $SECTION" >&2; exit 2 ;;
esac

for url in "$VM_URL/health" "$VMAGENT_URL/health"; do
  if ! curl -fsS -o /dev/null --max-time 3 "$url"; then
    echo "Нет ответа от $url — запущен ли scripts/port-forward.sh?" >&2
    exit 1
  fi
done

# q 'MetricsQL' — мгновенный запрос; печатает строки «метки  значение».
# Служебные метки (instance, node, container) скрыты, чтобы строки помещались в экран.
q() {
  echo "▸ $1"
  curl -fsS --get "$VM_URL/api/v1/query" --data-urlencode "query=$1" | python3 -I -c '
import json, sys
resp = json.load(sys.stdin)
if resp.get("status") != "success":
    sys.exit("  ошибка запроса: " + resp.get("error", "?"))
rows = resp["data"]["result"]
if not rows:
    print("  (нет данных)")
hidden = {"__name__", "instance", "node", "container"}
for row in rows:
    labels = ", ".join(f"{k}={v}" for k, v in sorted(row["metric"].items()) if k not in hidden)
    value = float(row["value"][1])
    shown = str(int(value)) if value.is_integer() else f"{value:.4g}"
    print(f"  {{{labels}}}  {shown}")
'
}

section() { [[ "$SECTION" == all || "$SECTION" == "$1" ]]; }
header() { echo; echo "=== $1"; }

if section targets; then
  header "Таргеты vmagent (service discovery по аннотациям prometheus.io/*)"
  curl -fsS "$VMAGENT_URL/targets" | sed -E 's/, (scrapes_total|scrape_response_size|samples_scraped)=[^,]*//g'
  echo
  # Собственные метрики vmagent: сколько подов видит discovery, сколько из них
  # стали таргетами, сколько таргетов up/down и сколько скрейпов было/упало.
  curl -fsS "$VMAGENT_URL/metrics" | grep -E \
    '^vm_promscrape_(discovery_kubernetes_(objects|scrape_works)\{role="pod"\}|targets\{type="kubernetes_sd_configs"|scrapes_total|scrapes_failed_total)'
fi

if section up; then
  header "up — успешность последнего скрейпа каждого таргета"
  q 'up'
  q 'count by (job) ({__name__!=""})'
fi

if section runtime; then
  header "Рантайм Python (prometheus_client: ProcessCollector, GCCollector, PlatformCollector)"
  q 'process_resident_memory_bytes{job="taskflow"}'
  q 'rate(process_cpu_seconds_total{job="taskflow"}[1m])'
  q 'process_open_fds{job="taskflow"}'
  q 'sum by (pod, generation) (increase(python_gc_collections_total{job="taskflow"}[5m]))'
  q 'time() - process_start_time_seconds{job="taskflow"}'
  q 'python_info{job="taskflow"}'
fi

if section http; then
  header "HTTP: запросы и задержка по маршрутам"
  # Накопленные значения, а не increase(): ряд по новой паре route+status появляется
  # с первым запросом, и его первую точку increase() за прирост не считает.
  q 'sum by (route, status_code) (http_request_duration_seconds_count{job="taskflow", route!~"/api/(health|ready)"})'
  q 'histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{job="taskflow"}[5m]))) > 0'
fi

if section business; then
  header "Бизнес-метрики TaskFlow (сумма по репликам)"
  q 'sum(taskflow_projects_created_total)'
  q 'sum(taskflow_projects_deleted_total)'
  q 'sum by (status) (taskflow_tasks_created_total)'
  q 'sum by (from, to) (taskflow_task_status_transitions_total) > 0'
  q 'sum(taskflow_task_lead_time_seconds_count)'
  q 'sum(taskflow_task_lead_time_seconds_sum) / sum(taskflow_task_lead_time_seconds_count)'
  q 'sum by (status) (taskflow_tasks_deleted_total)'
fi

if section postgres; then
  header "PostgreSQL (postgres-exporter)"
  q 'pg_up'
  q 'pg_stat_database_numbackends{datname="taskflow"}'
  q 'rate(pg_stat_database_xact_commit{datname="taskflow"}[5m])'
  q 'pg_database_size_bytes{datname="taskflow"}'
  q 'pg_stat_user_tables_n_live_tup{datname="taskflow"}'
fi
