#!/usr/bin/env bash
# Удаляет стек логирования. Приложение (namespace taskflow) не трогает —
# для него есть `kubectl delete -f k8s/app/`.
#
# ClusterRole/ClusterRoleBinding Vector'а — объекты уровня кластера, вместе
# с namespace они не удаляются, поэтому удаляем по манифестам, а не namespace.
#
# Чекпоинты и дисковый буфер Vector лежат на узле в /var/lib/vector (hostPath)
# и переживают удаление пода: при повторном деплое Vector продолжит с тех же
# позиций и НЕ перечитает историю в свежий Victoria Logs. Если нужен чистый
# старт с бэкфиллом (read_from: beginning), добавьте флаг:
#
# Использование: scripts/destroy.sh [--purge-node-state]
#   --purge-node-state  дополнительно `minikube ssh -- 'sudo rm -rf /var/lib/vector'`
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

PURGE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-node-state) PURGE=1 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
  shift
done

kubectl delete -f "$ROOT/k8s/logging/" --ignore-not-found --wait=true

if [[ "$PURGE" -eq 1 ]]; then
  echo "== Удаляем чекпоинты и буфер Vector на узле (/var/lib/vector)"
  minikube ssh -- 'sudo rm -rf /var/lib/vector'
fi
