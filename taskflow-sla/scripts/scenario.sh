#!/usr/bin/env bash
# Сценарий демонстрации SLI/SLO/SLA: по очереди вносит в TaskFlow сбои разного
# рода и снимает их, давая метрикам время отреагировать (~45 минут):
#
#   норма         4 мин   сбоев нет — исходные SLI
#   ошибки БД     6 мин   10 % запросов к БД падают → 5xx: availability, probes, service
#   норма         5 мин   сбой снят — бюджет больше не тратится, алерты гаснут
#   медленная БД  5 мин   +300 мс на запрос к БД → latency (ответы без ошибок)
#   норма         4 мин
#   БД остановлена 5 мин  PostgreSQL выключена → простой: database, probes, service
#   норма         8 мин   восстановление; быстрые алерты гаснут, бюджет остаётся потраченным
#
# --short — те же этапы короче (1/3/2/2/1/3/3 мин, ~15 минут): эффект виден,
# но окна короткие. Так записан скринкаст к отчёту.
#
# Сбои вносит scripts/fault.sh. Если прервать сценарий (Ctrl+C), внесённый
# сбой снимается — приложение не останется сломанным.
#
# Использование: scripts/scenario.sh [--short] [ФАЙЛ_ПОДПИСИ]
#   ФАЙЛ_ПОДПИСИ — куда писать текущий этап (две строки: этап, команда);
#   его читает покадровая запись дашборда (scripts/record-screencast.sh).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

SHORT=0
if [[ "${1:-}" == --short ]]; then SHORT=1; shift; fi
CAPTION="${1:-}"

# minutes ОБЫЧНО КОРОТКО — длительность этапа в зависимости от режима.
minutes() { if (( SHORT )); then echo "$2"; else echo "$1"; fi; }
FAULT="$ROOT/scripts/fault.sh"
app_fault=0
db_down=0

caption() {
  [[ -n "$CAPTION" ]] || return 0
  # Через временный файл и mv: читатель не увидит наполовину записанный файл.
  printf '%s\n%s\n' "$1" "$2" > "$CAPTION.tmp"
  mv "$CAPTION.tmp" "$CAPTION"
}

restore() {
  local status=$?
  trap - EXIT INT TERM
  if (( app_fault || db_down )); then
    echo
    echo "Сценарий прерван — снимаем внесённые сбои"
    # Каждый шаг — независимо: неудача одного не должна оставить другой сбой.
    if (( db_down )); then "$FAULT" db-up || status=1; fi
    if (( app_fault )); then "$FAULT" off || status=1; fi
  fi
  exit "$status"
}
trap restore EXIT
trap 'exit 130' INT TERM

# stage МИНУТ 'этап' [аргументы fault.sh] — объявляет этап, вносит или снимает
# сбой и ждёт, пока метрики отреагируют.
stage() {
  local minutes="$1" title="$2"; shift 2
  local cmd=""
  (( $# > 0 )) && cmd="scripts/fault.sh $*"
  echo
  echo "[$(date +%H:%M:%S)] == $title ($minutes мин)"
  caption "$title" "$cmd"
  if (( $# > 0 )); then
    echo "\$ $cmd"
    # Сбой отмечаем до команды (если она прервётся, его всё равно снимут),
    # снятие — после.
    case "$1" in
      errors|latency) app_fault=1 ;;
      db-down) db_down=1 ;;
    esac
    "$FAULT" "$@"
    case "$1" in
      off) app_fault=0 ;;
      db-up) db_down=0 ;;
    esac
  fi
  local m
  for ((m = 1; m <= minutes; m++)); do
    sleep 60
    echo "[$(date +%H:%M:%S)]   прошло $m из $minutes мин"
  done
}

require_tools kubectl

echo "Сбои перед началом:"
"$FAULT" status

stage "$(minutes 4 1)" "Норма: сбоев нет — исходные значения SLI, SLO и SLA"

stage "$(minutes 6 3)" "Ошибки БД: 10 % запросов падают → 5xx; минуты становятся плохими" errors 0.1
stage "$(minutes 5 2)" "Сбой снят: SLI вернулись, бюджет больше не тратится" off

stage "$(minutes 5 2)" "Медленная БД: +300 мс на запрос → SLI latency, ответы без ошибок" latency 300
stage "$(minutes 4 1)" "Задержка снята" off

stage "$(minutes 5 3)" "PostgreSQL остановлена → простой сервиса, пробы не проходят" db-down
stage "$(minutes 8 3)" "PostgreSQL вернулась: быстрые алерты гаснут, бюджет остаётся потраченным" db-up

caption "Сценарий завершён" ""
echo
echo "[$(date +%H:%M:%S)] Сценарий завершён. Итог: scripts/check-slo.sh"
