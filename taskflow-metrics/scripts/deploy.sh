#!/usr/bin/env bash
# Разворачивает приложение (образ taskflow:2.0 с метриками и postgres-exporter)
# и систему мониторинга: VictoriaMetrics single и vmagent из Helm-чартов
# в namespace monitoring. Ждёт готовности всего.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

for tool in kubectl helm minikube; do
  command -v "$tool" >/dev/null || { echo "Не найден $tool" >&2; exit 1; }
done

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

echo "== Мониторинг (namespace $NS_MON): VictoriaMetrics + vmagent из Helm-чартов"
kubectl apply -f "$ROOT/k8s/monitoring/00-namespace.yaml"
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" --force-update >/dev/null
helm repo update "$HELM_REPO_NAME" >/dev/null
# upgrade --install — идемпотентно: первый запуск ставит релиз, повторный обновляет.
helm upgrade --install "$VM_SINGLE_RELEASE" "$HELM_REPO_NAME/victoria-metrics-single" \
  --version "$VM_SINGLE_CHART_VERSION" --namespace "$NS_MON" \
  --values "$ROOT/k8s/monitoring/vmsingle-values.yaml" --wait --timeout 5m
helm upgrade --install "$VM_AGENT_RELEASE" "$HELM_REPO_NAME/victoria-metrics-agent" \
  --version "$VM_AGENT_CHART_VERSION" --namespace "$NS_MON" \
  --values "$ROOT/k8s/monitoring/vmagent-values.yaml" --wait --timeout 5m

echo
echo "== Приложение (namespace $NS_APP)"
kubectl apply -f "$ROOT/k8s/app/"
echo "Ждём PostgreSQL с экспортером..."
kubectl -n "$NS_APP" rollout status statefulset/db --timeout=180s
echo "Ждём приложение (init-контейнеры применят миграции, в том числе роль для экспортера)..."
kubectl -n "$NS_APP" rollout status deployment/taskflow --timeout=180s

echo
helm list -n "$NS_MON"
echo
kubectl get pods,svc -n "$NS_MON"
echo
kubectl get pods -n "$NS_APP"
echo
echo "Туннели к VictoriaMetrics и vmagent:  scripts/port-forward.sh"
echo "Трафик (наполнить бизнес-метрики):     scripts/generate-traffic.sh"
echo "Проверка сбора метрик:                 scripts/check-metrics.sh"
