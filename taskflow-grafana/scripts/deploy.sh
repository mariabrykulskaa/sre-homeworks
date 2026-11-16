#!/usr/bin/env bash
# Update Grafana only; retain the application, VictoriaMetrics and alerting stack.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_tools kubectl helm python3
kubectl -n "$NS_MON" get svc "$VM_SINGLE_SVC" >/dev/null
kubectl -n "$NS_MON" get secret "$GRAFANA_SECRET" >/dev/null
kubectl -n "$NS_MON" create configmap "$DASHBOARDS_CONFIGMAP" \
  --from-file="$ROOT/k8s/monitoring/dashboards/" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install "$GRAFANA_RELEASE" "$GRAFANA_REPO_NAME/grafana" \
  --version "$GRAFANA_CHART_VERSION" --namespace "$NS_MON" \
  --values "$ROOT/k8s/monitoring/grafana-values.yaml" --wait --timeout 5m
kubectl -n "$NS_MON" rollout status deployment/grafana --timeout=180s
echo "Grafana: http://127.0.0.1:3000/d/taskflow-overview"
