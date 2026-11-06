#!/usr/bin/env bash
# Удаляет всё, что создал deploy.sh, включая том с данными PostgreSQL
# (PVC удаляется вместе с namespace, PV в minikube — политика Delete).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

kubectl delete namespace "$NS" --ignore-not-found --wait=true
