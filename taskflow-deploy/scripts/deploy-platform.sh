#!/usr/bin/env bash
# Разворачивает общую часть стенда: namespace, конфигурацию, PostgreSQL и
# шлюз (GatewayClass eg, EnvoyProxy, Gateway eg, политику соединений).
# Нужны установленный Envoy Gateway (scripts/install-envoy-gateway.sh) и образы
# (scripts/build-images.sh). Стратегии разворачивают scripts/demo-*.sh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

kubectl apply -f "$ROOT/k8s/platform/"
kubectl apply -f "$ROOT/k8s/gateway/"

kubectl -n "$NS" rollout status statefulset/db --timeout=300s
kubectl -n "$NS" wait --for=condition=Programmed gateway/eg --timeout=300s
kubectl -n "$EG_NS" wait --for=condition=Available deployment -l "$envoy_selector" --timeout=300s

echo
kubectl get gatewayclass eg
kubectl -n "$NS" get gateway,pods
echo "Прокси Envoy: $EG_NS/$(envoy_service)"
