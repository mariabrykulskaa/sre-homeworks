#!/usr/bin/env bash
# Собирает образы приложения (taskflow:2.0 — с внесением сбоев) и пробера
# (taskflow-prober:2.0) docker-демоном внутри minikube. После этого образы
# сразу видны kubelet'у — отдельная загрузка не нужна.
#
# Использование: scripts/build-image.sh [app|prober|all]   (по умолчанию all)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

TARGET="${1:-all}"
case "$TARGET" in
  app|prober|all) ;;
  *) echo "Использование: $0 [app|prober|all]" >&2; exit 2 ;;
esac

require_tools minikube docker

# Переключаем docker CLI на демон minikube (bash/zsh: eval $(minikube docker-env);
# fish: minikube docker-env | source). Отдельным присваиванием: если minikube
# не запущен, set -e остановит скрипт, а не соберёт образ молча на демоне хоста.
docker_env="$(minikube docker-env --shell bash)"
eval "$docker_env"

build() {
  local image="$1" dir="$2"
  if [[ ! -f "$dir/Dockerfile" ]]; then
    echo "Dockerfile не найден в $dir" >&2
    exit 1
  fi
  echo "== $image из $dir"
  docker build -t "$image" "$dir"
}

if [[ "$TARGET" == app || "$TARGET" == all ]]; then
  build "$APP_IMAGE" "$APP_DIR"
fi
if [[ "$TARGET" == prober || "$TARGET" == all ]]; then
  build "$PROBER_IMAGE" "$PROBER_DIR"
fi

echo
echo "Образы внутри minikube:"
minikube image ls | grep -E "(^|/)taskflow(-prober)?:" || true
