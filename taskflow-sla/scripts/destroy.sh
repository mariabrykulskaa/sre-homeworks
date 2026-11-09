#!/usr/bin/env bash
# Удаляет мониторинг ДЗ №5: пробер, Helm-релизы Grafana, vmalert, vmagent и
# VictoriaMetrics и namespace monitoring (вместе с Secret и ConfigMap'ами).
# Приложение (namespace taskflow) не трогает — для него есть `kubectl delete -f k8s/app/`.
#
# ClusterRole/ClusterRoleBinding vmagent — объекты уровня кластера; их удаляет
# `helm uninstall`, удаление одного namespace их бы оставило.
# PVC VictoriaMetrics Helm не удаляет — он уходит вместе с namespace, данные
# метрик теряются.
#
# Использование: scripts/destroy.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

require_tools kubectl helm

kubectl delete -f "$ROOT/k8s/monitoring/30-prober.yaml" --ignore-not-found
for release in "$GRAFANA_RELEASE" "$VMALERT_RELEASE" "$VM_AGENT_RELEASE" "$VM_SINGLE_RELEASE"; do
  if helm status "$release" -n "$NS_MON" >/dev/null 2>&1; then
    helm uninstall "$release" -n "$NS_MON" --wait
  fi
done

kubectl delete -f "$ROOT/k8s/monitoring/00-namespace.yaml" --ignore-not-found --wait=true
