#!/usr/bin/env bash
# Разворачивает приложение и его зависимости в minikube и ждёт готовности.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# В манифестах imagePullPolicy: Never — без образа в кеше minikube поды
# зависнут в ErrImageNeverPull. Проверяем заранее, чтобы ошибка была понятной.
# Тег берём из манифеста, чтобы проверка не разошлась с ним после обновления.
IMAGE="$(grep -m1 -E '^[[:space:]]*image:[[:space:]]*taskflow:' "$ROOT/k8s/20-app.yaml" | awk '{print $2}' || true)"
if [[ -z "$IMAGE" ]]; then
  echo "В $ROOT/k8s/20-app.yaml не найдена строка image: taskflow:<тег>" >&2
  exit 1
fi
images="$(minikube image ls)"   # при остановленном minikube упадёт здесь с его же ошибкой
# Точное совпадение имени с тегом (а не подстрока: taskflow:2.0 ≠ taskflow:2.0.1).
if ! grep -qE "(^|/)${IMAGE//./\\.}\$" <<<"$images"; then
  echo "Образ $IMAGE не найден в minikube. Сначала: scripts/build-image.sh $IMAGE" >&2
  exit 1
fi

kubectl apply -f "$ROOT/k8s/"

echo
echo "Ждём PostgreSQL..."
kubectl -n "$NS" rollout status statefulset/db --timeout=180s

echo "Ждём приложение (init-контейнеры применят миграции)..."
kubectl -n "$NS" rollout status deployment/taskflow --timeout=180s

echo
kubectl -n "$NS" get pods -o wide
echo
echo "Открыть UI:  minikube service taskflow -n $NS"
