#!/usr/bin/env bash
# Альтернатива build-image.sh: собрать образ обычным docker-демоном хоста
# и загрузить его в minikube командой `minikube image load`.
#
# Использование: scripts/load-image.sh [тег]   (по умолчанию taskflow:1.0)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

IMAGE="${1:-$IMAGE_DEFAULT}"

if [[ ! -f "$APP_DIR/Dockerfile" ]]; then
  echo "Dockerfile не найден в $APP_DIR (задайте APP_DIR=путь/к/исходникам)" >&2
  exit 1
fi

docker build -t "$IMAGE" "$APP_DIR"
minikube image load "$IMAGE"

echo
echo "Образ $IMAGE загружен в minikube:"
minikube image ls | grep -F "${IMAGE%%:*}" || true
