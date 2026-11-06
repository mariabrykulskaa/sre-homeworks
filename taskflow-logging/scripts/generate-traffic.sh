#!/usr/bin/env bash
# Генерирует разнообразный трафик к приложению, чтобы в Victoria Logs было
# что искать: успешные запросы (info), ошибки клиента (warn) и — по флагу —
# ошибки сервера (error) во время имитации сбоя базы.
#
# Использование: scripts/generate-traffic.sh [--db-outage] [--rounds N]
#   --db-outage  удалить под db-0 и, пока он поднимается, слать запросы:
#                readiness-проба и API начнут отвечать 503/500 с level=error.
#                PostgreSQL в StatefulSet пересоздаётся сам, данные на PVC.
#   --rounds N   сколько раз повторить основной цикл запросов (по умолчанию 5)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

DB_OUTAGE=0
ROUNDS=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-outage) DB_OUTAGE=1 ;;
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
# port-forward работает одинаково на всех платформах.
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

# req METHOD PATH [JSON] — печатает код ответа, ошибки HTTP не прерывают скрипт.
req() {
  local method="$1" path="$2" body="${3:-}" code
  if [[ -n "$body" ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X "$method" \
      -H 'Content-Type: application/json' -H "X-Request-Id: traffic-$RANDOM" \
      --data "$body" "$APP$path")"
  else
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X "$method" \
      -H "X-Request-Id: traffic-$RANDOM" "$APP$path")"
  fi
  printf '%-6s %-32s %s\n' "$method" "$path" "$code"
}

echo "== Основной трафик ($ROUNDS раундов)"
for round in $(seq 1 "$ROUNDS"); do
  project_id="$(curl -sS -X POST -H 'Content-Type: application/json' \
    --data "{\"name\":\"Проект $round\",\"description\":\"трафик для логов\"}" \
    "$APP/api/projects" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')"
  printf 'POST   %-32s 201 (id=%s)\n' /api/projects "$project_id"

  for i in 1 2 3; do
    req POST /api/tasks "{\"project_id\":$project_id,\"title\":\"Задача $round.$i\",\"status\":\"todo\"}"
  done
  req GET  "/api/tasks?project_id=$project_id"
  req GET  "/api/projects/$project_id"
  req PUT  "/api/projects/$project_id" '{"description":"обновлено"}'
  req GET  /api/projects
  req GET  /api/ready
  # Ошибки клиента → level=warn
  req GET  /api/projects/999999                                  # 404
  req POST /api/tasks '{"title":"без проекта"}'                   # 400: нет project_id
  req POST /api/projects '{"name":""}'                            # 400: пустое имя
  req GET  '/api/tasks?status=unknown'                            # 400: неверный статус
  req GET  /api/nope                                              # 404
  req POST /api/projects '{broken json'                           # 400: битый JSON
  req DELETE "/api/projects/$project_id"                          # 204
done

if [[ "$DB_OUTAGE" -eq 1 ]]; then
  echo
  echo "== Имитация сбоя базы: удаляем под db-0 (StatefulSet поднимет его заново)"
  kubectl -n "$NS_APP" delete pod db-0 --wait=false
  # Пока база недоступна: readiness-проба и запросы к БД пишут level=error.
  for _ in $(seq 1 15); do
    req GET  /api/ready
    req GET  /api/projects
    req POST /api/projects '{"name":"во время сбоя"}'
    sleep 1
  done
  echo "Ждём, пока база вернётся..."
  kubectl -n "$NS_APP" rollout status statefulset/db --timeout=180s
  req GET /api/ready
fi

echo
echo "Готово. Логи появятся в Victoria Logs в течение пары секунд."
