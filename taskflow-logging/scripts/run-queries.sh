#!/usr/bin/env bash
# Выполняет через HTTP API запросы, эквивалентные LogsQL-запросам из Отчёт.md
# (vmui делает ровно то же самое: POST /select/logsql/query). Отличия от отчёта —
# только в объёме вывода: у запросов (а) и (б) добавлены `limit` и `fields`,
# чтобы в терминал не лились все поля сотен записей; агрегаты (в)–(г′) те же.
# Напоминание: поле message приложения при приёме становится _msg, timestamp — _time
# (параметры _msg_field/_time_field в конфигурации Vector).
# Нужен туннель до Victoria Logs: scripts/port-forward.sh (или VL_URL=...).
#
# Использование: scripts/run-queries.sh [ОКНО_МИНУТ]
#   ОКНО_МИНУТ — за сколько последних минут брать записи (`_time:<N>m` в каждом
#   запросе); по умолчанию 30. Счётчики, разумеется, зависят от окна и момента
#   запуска и не обязаны совпадать с числами на скриншотах в отчёте.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

MINUTES="${1:-30}"
if ! [[ "$MINUTES" =~ ^[1-9][0-9]*$ ]]; then
  echo "Ожидается положительное число минут, получено «$MINUTES»" >&2
  exit 2
fi

if ! curl -fsS -o /dev/null "$VL_URL/health"; then
  echo "Victoria Logs недоступен на $VL_URL — запустите scripts/port-forward.sh" >&2
  exit 1
fi

# query ЗАГОЛОВОК LOGSQL [limit]
query() {
  local title="$1" logsql="$2" limit="${3:-}"
  echo
  echo "### $title"
  echo "    $logsql"
  echo
  curl -fsS "$VL_URL/select/logsql/query" \
    --data-urlencode "query=$logsql" \
    ${limit:+--data-urlencode "limit=$limit"}
}

query "(а) сырые записи приложения за последние $MINUTES минут (10 последних)" \
  "_time:${MINUTES}m service.name:taskflow | sort by (_time) desc | limit 10 | fields _time, level, _msg, kubernetes.pod, request_id, method, path, status" 10

query "(б) только ошибки приложения" \
  "_time:${MINUTES}m service.name:taskflow level:error | sort by (_time) desc | fields _time, _msg, error.message, path, request_id" 10

query "(в) stats: число записей по сервису и уровню" \
  "_time:${MINUTES}m | stats by (service.name, level) count() as records | sort by (service.name, level)"

query "(г) агрегаты по access-логу: запросы по путям, p95 длительности, сколько реплик их обслуживало" \
  "_time:${MINUTES}m service.name:taskflow _msg:request | stats by (method, path) count() as requests, quantile(0.95, duration_ms) as p95_ms, count_uniq(kubernetes.pod) as pods | sort by (requests desc) | limit 10"

echo
query "(г') top: самые частые пути ответов с ошибкой клиента/сервера" \
  "_time:${MINUTES}m service.name:taskflow _msg:request status:>=400 | top 5 by (status, path)"
echo
