#!/usr/bin/env bash
# Демонстрация алертов ДЗ №6: вносит сбои в TaskFlow, ждёт, пока сработают
# алерты, и показывает, что уведомления дошли до почты дежурного (Mailpit).
#
#   fire      очистить ящик Mailpit; выкатить ревизию с 20 % ошибок БД и
#             «утечкой» 160 МБ памяти; перезапустить процесс в одном поде;
#             дождаться алертов сервиса (TaskflowHighErrorRate, TaskflowProbeFailing)
#             и рантайма (TaskflowHighMemoryUsage, TaskflowProcessRestarted)
#   recover   снять сбои и дождаться, пока алерты погаснут (письма RESOLVED)
#   status    горящие алерты vmalert и письма в Mailpit
#
# Нужны туннели scripts/port-forward.sh (vmalert :8880, Mailpit :8025).
# Использование: scripts/alert-demo.sh fire | recover | status
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_tools kubectl curl python3

DEMO_ALERTS=(TaskflowHighErrorRate TaskflowProbeFailing TaskflowHighMemoryUsage TaskflowProcessRestarted)
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"

stamp() { date '+%H:%M:%S'; }
step() { printf '\n[%s] == %s\n' "$(stamp)" "$*"; }

# Состояние алерта в vmalert: firing | pending | (пусто — не горит).
alert_state() {
  curl -fsS "$VMALERT_URL/api/v1/alerts" | python3 -I -c '
import json, sys
name = sys.argv[1]
states = {a["state"] for a in json.load(sys.stdin)["data"]["alerts"] if a["name"] == name}
print("firing" if "firing" in states else "pending" if "pending" in states else "")' "$1"
}

wait_for() {  # wait_for СОСТОЯНИЕ АЛЕРТ… — ждать, пока каждый алерт придёт в состояние
  local want="$1"; shift
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS)) name
  for name in "$@"; do
    until [[ "$(alert_state "$name")" == "$want" ]]; do
      if (( SECONDS > deadline )); then
        echo "Не дождались: $name → ${want:-погас}" >&2
        exit 1
      fi
      sleep 5
    done
    printf '[%s]   %-28s %s\n' "$(stamp)" "$name" "${want:-погас}"
  done
}

show_status() {
  echo "Горящие алерты vmalert:"
  curl -fsS "$VMALERT_URL/api/v1/alerts" | python3 -I -c '
import json, sys
alerts = json.load(sys.stdin)["data"]["alerts"]
for a in sorted(alerts, key=lambda a: a["name"]):
    l = a["labels"]
    extra = " ".join(k + "=" + l[k] for k in ("pod", "slo") if k in l)
    print("  %-8s %-28s %-9s %s" % (a["state"], a["name"], l.get("severity", ""), extra))
print("  всего:", len(alerts))'
  echo "Письма в Mailpit ($MAILPIT_URL):"
  curl -fsS "$MAILPIT_URL/api/v1/messages?limit=20" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
for m in d["messages"]:
    to = ", ".join(t["Address"] for t in m["To"])
    print("  %s  %s  → %s" % (m["Created"][11:19], m["Subject"], to))
print("  всего:", d["total"])'
}

require_tunnel "$VMALERT_URL/health" vmalert
require_tunnel "$MAILPIT_URL/livez" Mailpit

case "${1:-}" in
  fire)
    step "Очищаем ящик дежурного в Mailpit"
    curl -fsS -X DELETE "$MAILPIT_URL/api/v1/messages" >/dev/null

    step "Выкатываем ревизию с дефектом: 20 % запросов к БД падают, каждая реплика держит 160 МБ"
    kubectl -n "$NS_APP" set env deployment/taskflow -c taskflow FAULT_ERROR_RATE=0.2 FAULT_MEMORY_MB=160
    kubectl -n "$NS_APP" rollout status deployment/taskflow --timeout=180s

    # Пауза: vmagent (раз в 15 с) должен увидеть процесс до перезапуска. Иначе для
    # алерта это «новый под с одним временем старта» — и он, как задумано, промолчит.
    step "Ждём 60 с, чтобы vmagent запомнил время старта процессов новой ревизии"
    sleep 60

    step "Перезапускаем процесс в одном поде (как падение)"
    "$ROOT/scripts/fault.sh" restart

    step "Ждём срабатывания алертов (pending → firing после паузы for)"
    wait_for firing "${DEMO_ALERTS[@]}"
    step "Даём Alertmanager разослать письма (group_wait)"
    sleep 40
    show_status
    ;;
  recover)
    step "Снимаем сбои"
    "$ROOT/scripts/fault.sh" off
    step "Ждём, пока алерты погаснут"
    # Перезапуск остаётся в окне 15 минут — этот алерт гаснет последним.
    wait_for "" TaskflowHighErrorRate TaskflowProbeFailing TaskflowHighMemoryUsage TaskflowProcessRestarted
    sleep 40
    show_status
    ;;
  status)
    show_status
    ;;
  -h|--help)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
