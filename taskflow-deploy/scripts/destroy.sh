#!/usr/bin/env bash
# Удаляет стенд ДЗ №8: namespace taskflow-deploy (стратегии, PostgreSQL, Gateway)
# и GatewayClass eg. Стенд прошлых ДЗ (namespace taskflow, monitoring, logging)
# не затрагивается.
#
# Использование: scripts/destroy.sh [--uninstall-gateway]
#   --uninstall-gateway — удалить и сам Envoy Gateway (контроллер, CRD Gateway API).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

kubectl delete namespace "$NS" --ignore-not-found --wait=true
kubectl delete gatewayclass eg --ignore-not-found
# hostPath-провижинер minikube не стирает данные удалённого PVC; без этого новый
# PVC с тем же именем получил бы старую базу.
minikube ssh -- "sudo rm -rf /tmp/hostpath-provisioner/$NS" || true

if [[ "${1:-}" == --uninstall-gateway ]]; then
  kubectl delete -f "https://github.com/envoyproxy/gateway/releases/download/${EG_VERSION}/install.yaml" \
    --ignore-not-found
fi
