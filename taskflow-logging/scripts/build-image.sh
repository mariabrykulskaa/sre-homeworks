#!/usr/bin/env bash
# Собирает образ приложения docker-демоном внутри minikube.
# После этого образ сразу виден kubelet'у — отдельная загрузка не нужна.
#
# Использование: scripts/build-image.sh [тег]   (по умолчанию taskflow:1.1)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

IMAGE="${1:-$IMAGE_DEFAULT}"

if [[ ! -f "$APP_DIR/Dockerfile" ]]; then
  echo "Dockerfile не найден в $APP_DIR (задайте APP_DIR=путь/к/исходникам)" >&2
  exit 1
fi

# Переключаем docker CLI на демон minikube (bash/zsh: eval $(minikube docker-env);
# fish: minikube docker-env | source). Отдельным присваиванием: если minikube
# не запущен, set -e остановит скрипт, а не соберёт образ молча на демоне хоста.
docker_env="$(minikube docker-env --shell bash)"
eval "$docker_env"

docker build -t "$IMAGE" "$APP_DIR"

echo
echo "Образ $IMAGE собран внутри minikube:"
minikube image ls | grep -F "${IMAGE%%:*}" || true
