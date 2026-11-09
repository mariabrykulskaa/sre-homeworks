#!/usr/bin/env bash
# Меняет поведение TaskFlow для демонстрации SLI/SLO/SLA и алертов.
#
#   errors ДОЛЯ   доля запросов к БД, которые падают с ошибкой (0…1) → ответы 5xx
#   latency МС    задержка перед каждым запросом к БД (0…30000 мс) → медленные ответы
#   memory МБ     «утечка памяти»: каждая реплика держит балласт (0…1024 МБ) → рост RSS
#   restart       перезапустить процесс в одном поде (как падение) → смена времени старта
#   off           убрать внесённые сбои приложения
#   db-down       остановить PostgreSQL (StatefulSet db → 0 реплик)
#   db-up         вернуть PostgreSQL и дождаться приложения
#   status        текущие сбои: переменные FAULT_* и число реплик БД
#
# Сбои приложения — переменные окружения FAULT_ERROR_RATE, FAULT_LATENCY_MS и
# FAULT_MEMORY_MB (taskflow/faults.py в ../app). `kubectl set env` выкатывает новую
# ревизию Deployment — как релиз с дефектом; RollingUpdate (maxUnavailable: 0) меняет
# поды по одному, без простоя. Значения проверяются здесь же: под с неверным
# значением не стартовал бы (приложение падает на старте с понятной ошибкой).
#
# Использование: scripts/fault.sh errors 0.05 | latency 300 | memory 160 | restart | off | db-down | db-up | status
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,11p;19p' "$0" | sed 's/^# \{0,1\}//'; }

set_app_env() {
  kubectl -n "$NS_APP" set env deployment/taskflow -c taskflow "$@"
  kubectl -n "$NS_APP" rollout status deployment/taskflow --timeout=180s
}

show_status() {
  echo "Переменные FAULT_* контейнера taskflow:"
  kubectl -n "$NS_APP" set env deployment/taskflow -c taskflow --list | grep '^FAULT_' \
    || echo "  (нет — сбоев в приложении нет)"
  echo "Реплик PostgreSQL: $(kubectl -n "$NS_APP" get statefulset db -o jsonpath='{.spec.replicas}')"
}

case "${1:-}" in
  errors)
    rate="${2:-}"
    if ! python3 -I -c 'import sys; v = float(sys.argv[1]); sys.exit(0 if 0 <= v <= 1 else 1)' "$rate" 2>/dev/null; then
      echo "errors: ожидается доля от 0 до 1, получено «$rate»" >&2
      exit 2
    fi
    set_app_env "FAULT_ERROR_RATE=$rate"
    ;;
  latency)
    ms="${2:-}"
    if ! [[ "$ms" =~ ^[0-9]+$ ]] || (( ms > 30000 )); then
      echo "latency: ожидается целое число миллисекунд от 0 до 30000, получено «$ms»" >&2
      exit 2
    fi
    set_app_env "FAULT_LATENCY_MS=$ms"
    ;;
  memory)
    mb="${2:-}"
    if ! [[ "$mb" =~ ^[0-9]+$ ]] || (( mb > 1024 )); then
      echo "memory: ожидается целое число мегабайт от 0 до 1024, получено «$mb»" >&2
      exit 2
    fi
    set_app_env "FAULT_MEMORY_MB=$mb"
    ;;
  restart)
    # SIGTERM процессу Python (PID 1 контейнера): он корректно завершается, kubelet
    # запускает контейнер заново в том же поде — меняется process_start_time_seconds.
    pod="$(kubectl -n "$NS_APP" get pods -l app.kubernetes.io/name=taskflow -o jsonpath='{.items[0].metadata.name}')"
    echo "Перезапускаем процесс в поде $pod"
    kubectl -n "$NS_APP" exec "$pod" -c taskflow -- python -c 'import os, signal; os.kill(1, signal.SIGTERM)'
    sleep 3
    kubectl -n "$NS_APP" wait --for=condition=Ready "pod/$pod" --timeout=120s
    kubectl -n "$NS_APP" get pod "$pod" -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,READY:.status.containerStatuses[0].ready'
    ;;
  off)
    set_app_env FAULT_ERROR_RATE- FAULT_LATENCY_MS- FAULT_MEMORY_MB-
    ;;
  db-down)
    kubectl -n "$NS_APP" scale statefulset/db --replicas=0
    kubectl -n "$NS_APP" wait --for=delete pod/db-0 --timeout=120s
    ;;
  db-up)
    kubectl -n "$NS_APP" scale statefulset/db --replicas=1
    kubectl -n "$NS_APP" rollout status statefulset/db --timeout=180s
    # Приложение само переподключается к БД; ждём, пока поды снова станут готовы.
    kubectl -n "$NS_APP" wait --for=condition=Ready pod -l app.kubernetes.io/name=taskflow --timeout=120s
    ;;
  status)
    show_status
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
