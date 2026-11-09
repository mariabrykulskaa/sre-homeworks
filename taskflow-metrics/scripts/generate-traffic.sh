#!/usr/bin/env bash
# Генерирует трафик к приложению, чтобы у бизнес-метрик и HTTP-метрик были
# данные: проекты создаются и удаляются, задачи создаются, проходят по
# статусам todo → in_progress → done и удаляются; плюс запросы с ошибками
# клиента (4xx) для http_request_duration_seconds.
#
# Использование: scripts/generate-traffic.sh [--rounds N]
#   --rounds N   сколько раз повторить сценарий (по умолчанию 5)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

ROUNDS=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rounds) ROUNDS="${2:?--rounds требует число}"; shift ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
  shift
done
if ! [[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "--rounds: ожидается положительное число, получено «$ROUNDS»" >&2
  exit 2
fi

# Туннель до Service приложения: на macOS NodePort minikube снаружи недоступен,
# port-forward работает одинаково на всех платформах. kubectl port-forward
# svc/… соединяется с одним подом Service (без kube-proxy), поэтому весь трафик
# придёт в одну реплику — суммы по репликам (sum() в запросах) от этого не меняются.
APP_PORT="${APP_LOCAL_PORT:-18080}"
APP="http://127.0.0.1:${APP_PORT}"
kubectl -n "$NS_APP" port-forward svc/taskflow "${APP_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  curl -fsS -o /dev/null "$APP/api/health" 2>/dev/null && break
  sleep 1
done
if ! curl -fsS -o /dev/null "$APP/api/health"; then
  echo "Приложение не отвечает через port-forward на $APP" >&2
  exit 1
fi

# req METHOD PATH [JSON] — печатает код ответа; ошибки HTTP не прерывают скрипт.
req() {
  local method="$1" path="$2" body="${3:-}" args=()
  [[ -n "$body" ]] && args=(-H 'Content-Type: application/json' --data "$body")
  printf '%-6s %-34s %s\n' "$method" "$path" \
    "$(curl -sS -o /dev/null -w '%{http_code}' -X "$method" ${args[@]+"${args[@]}"} "$APP$path")"
}

# create PATH JSON — POST, печатает код и возвращает id созданного объекта.
create() {
  local path="$1" body="$2" id
  id="$(curl -fsS -X POST -H 'Content-Type: application/json' --data "$body" "$APP$path" \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')"
  printf 'POST   %-34s 201 (id=%s)\n' "$path" "$id" >&2
  echo "$id"
}

for round in $(seq 1 "$ROUNDS"); do
  echo "== Раунд $round из $ROUNDS"
  project="$(create /api/projects "{\"name\":\"Релиз $round\",\"description\":\"трафик для метрик\"}")"

  # Задачи: три новых (todo) и одна сразу в работе.
  t1="$(create /api/tasks "{\"project_id\":$project,\"title\":\"Спецификация $round\"}")"
  t2="$(create /api/tasks "{\"project_id\":$project,\"title\":\"Реализация $round\"}")"
  t3="$(create /api/tasks "{\"project_id\":$project,\"title\":\"Документация $round\"}")"
  create /api/tasks "{\"project_id\":$project,\"title\":\"Ревью $round\",\"status\":\"in_progress\"}" >/dev/null

  # Движение по статусам: переходы и время выполнения (lead time).
  req PUT "/api/tasks/$t1" '{"status":"in_progress"}'
  req PUT "/api/tasks/$t1" '{"status":"done"}'
  req PUT "/api/tasks/$t2" '{"status":"in_progress"}'
  req PUT "/api/tasks/$t2" '{"title":"Реализация (уточнено)"}'   # не переход: статус тот же
  if (( round % 2 == 0 )); then
    req PUT "/api/tasks/$t2" '{"status":"done"}'
    req PUT "/api/tasks/$t2" '{"status":"todo"}'                # переоткрыта
  fi
  req PUT "/api/tasks/$t3" '{"status":"done"}'

  # Чтение.
  req GET "/api/tasks?project_id=$project"
  req GET "/api/tasks?status=done"
  req GET "/api/projects/$project"
  req GET /api/projects

  # Ошибки клиента (4xx): метрики считают их по маршрутам и статусам.
  req GET  /api/projects/999999                     # 404
  req POST /api/tasks '{"title":"без проекта"}'      # 400
  req GET  '/api/tasks?status=unknown'               # 400
  req POST /api/projects '{broken json'              # 400, до маршрутизации → route=unmatched

  # Удаление: задача — всегда, проект (вместе с задачами) — каждый третий раунд.
  req DELETE "/api/tasks/$t3"
  if (( round % 3 == 0 )); then
    req DELETE "/api/projects/$project"
  fi
done

echo
# Скрейп раз в 15 с плюс -search.latencyOffset=30s: VictoriaMetrics не отдаёт
# в запросах точки моложе 30 с, чтобы не показывать неполные данные.
echo "Готово. Новые значения будут видны в запросах к VictoriaMetrics примерно через 45 с"
echo "(скрейп vmagent раз в 15 с + 30 с задержки видимости в VictoriaMetrics)."
