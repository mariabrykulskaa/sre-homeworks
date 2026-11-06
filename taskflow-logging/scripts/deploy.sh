#!/usr/bin/env bash
# Разворачивает приложение (манифесты ДЗ №2 с новым образом) и стек логирования
# (Victoria Logs + Vector) в minikube и ждёт готовности всего.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# В манифестах imagePullPolicy: Never — без образа в кеше minikube поды
# зависнут в ErrImageNeverPull. Проверяем заранее, чтобы ошибка была понятной.
IMAGE="$(grep -m1 -E '^[[:space:]]*image:[[:space:]]*taskflow:' "$ROOT/k8s/app/20-app.yaml" | awk '{print $2}' || true)"
if [[ -z "$IMAGE" ]]; then
  echo "В $ROOT/k8s/app/20-app.yaml не найдена строка image: taskflow:<тег>" >&2
  exit 1
fi
images="$(minikube image ls)"   # при остановленном minikube упадёт здесь с его же ошибкой
if ! grep -qE "(^|/)${IMAGE//./\\.}\$" <<<"$images"; then
  echo "Образ $IMAGE не найден в minikube. Сначала: scripts/build-image.sh $IMAGE" >&2
  exit 1
fi

echo "== Приложение (namespace $NS_APP)"
kubectl apply -f "$ROOT/k8s/app/"
echo
echo "== Логирование (namespace $NS_LOG)"
kubectl apply -f "$ROOT/k8s/logging/"

echo
echo "Ждём PostgreSQL..."
kubectl -n "$NS_APP" rollout status statefulset/db --timeout=180s
echo "Ждём приложение (init-контейнеры применят миграции)..."
kubectl -n "$NS_APP" rollout status deployment/taskflow --timeout=180s
echo "Ждём Victoria Logs..."
kubectl -n "$NS_LOG" rollout status deployment/victoria-logs --timeout=180s
echo "Ждём Vector..."
kubectl -n "$NS_LOG" rollout status daemonset/vector --timeout=180s
echo "Ждём Alertmanager и vmalert (бонус)..."
kubectl -n "$NS_LOG" rollout status deployment/alertmanager --timeout=180s
kubectl -n "$NS_LOG" rollout status deployment/vmalert --timeout=180s

echo
kubectl get pods -o wide -n "$NS_APP"
kubectl get pods,pvc -o wide -n "$NS_LOG"
echo
echo "vmui:      scripts/port-forward.sh  →  $VL_URL/select/vmui/"
echo "vmalert:   $VMALERT_URL/vmalert/   Alertmanager: $AM_URL/"
echo "трафик:    scripts/generate-traffic.sh"
echo "запросы:   scripts/run-queries.sh"
