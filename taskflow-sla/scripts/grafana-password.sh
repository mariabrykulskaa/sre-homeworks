#!/usr/bin/env bash
# Печатает пароль администратора Grafana (пользователь admin) из Secret,
# который создал scripts/deploy.sh.
#
# Использование: scripts/grafana-password.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

kubectl -n "$NS_MON" get secret "$GRAFANA_SECRET" \
  -o jsonpath='{.data.admin-password}' | base64 --decode
echo
