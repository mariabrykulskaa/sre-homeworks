#!/usr/bin/env bash
# Ставит Envoy Gateway (контроллер + CRD Gateway API) в minikube — как в
# quickstart Envoy Gateway. Используется официальный install.yaml релиза:
# CRD Gateway API (standard + experimental) и CRD Envoy Gateway, контроллер
# в namespace envoy-gateway-system. Повторный запуск безопасен.
#
# То же через Helm:
#   helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.4 \
#     -n envoy-gateway-system --create-namespace
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

url="https://github.com/envoyproxy/gateway/releases/download/${EG_VERSION}/install.yaml"
echo "Envoy Gateway $EG_VERSION: $url"
# --server-side: CRD Gateway API крупнее лимита аннотации last-applied-configuration.
kubectl apply --server-side --force-conflicts -f "$url"

kubectl -n "$EG_NS" wait --for=condition=Available deployment/envoy-gateway --timeout=300s
kubectl -n "$EG_NS" get pods
kubectl get crd -o name | grep -E 'gateway.networking.k8s.io|gateway.envoyproxy.io' | sort
