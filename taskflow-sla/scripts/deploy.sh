#!/usr/bin/env bash
# Разворачивает всё для ДЗ №5 и ждёт готовности:
#   monitoring: VictoriaMetrics single и vmagent (как в ДЗ №4), vmalert с
#               правилами SLO, Grafana с дашбордом SLI/SLO/SLA, пробер TaskFlow;
#   taskflow:   приложение taskflow:2.0 (с внесением сбоев) и PostgreSQL с экспортером.
# Повторный запуск безопасен: Helm-релизы обновляются, ConfigMap'ы с правилами и
# дашбордом пересобираются из файлов репозитория, пароль Grafana сохраняется.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

require_tools kubectl helm minikube python3

# В манифестах imagePullPolicy: Never — без образа в кеше minikube поды
# зависнут в ErrImageNeverPull. Проверяем заранее, чтобы ошибка была понятной.
images="$(minikube image ls)"   # при остановленном minikube упадёт здесь с его же ошибкой
for image in "$APP_IMAGE" "$PROBER_IMAGE"; do
  if ! grep -qE "(^|/)${image//./\\.}\$" <<<"$images"; then
    echo "Образ $image не найден в minikube. Сначала: scripts/build-image.sh" >&2
    exit 1
  fi
done

echo "== Мониторинг (namespace $NS_MON): VictoriaMetrics + vmagent"
kubectl apply -f "$ROOT/k8s/monitoring/00-namespace.yaml"
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" --force-update >/dev/null
helm repo add "$GRAFANA_REPO_NAME" "$GRAFANA_REPO_URL" --force-update >/dev/null
helm repo update "$HELM_REPO_NAME" "$GRAFANA_REPO_NAME" >/dev/null
# upgrade --install — идемпотентно: первый запуск ставит релиз, повторный обновляет.
helm upgrade --install "$VM_SINGLE_RELEASE" "$HELM_REPO_NAME/victoria-metrics-single" \
  --version "$VM_SINGLE_CHART_VERSION" --namespace "$NS_MON" \
  --values "$ROOT/k8s/monitoring/vmsingle-values.yaml" --wait --timeout 5m
helm upgrade --install "$VM_AGENT_RELEASE" "$HELM_REPO_NAME/victoria-metrics-agent" \
  --version "$VM_AGENT_CHART_VERSION" --namespace "$NS_MON" \
  --values "$ROOT/k8s/monitoring/vmagent-values.yaml" --wait --timeout 5m

# apply_configmap ИМЯ --from-file=… — создаёт или обновляет ConfigMap из файлов.
# `kubectl create` не умеет обновлять; через --dry-run → apply — умеет.
apply_configmap() {
  local name="$1"; shift
  kubectl -n "$NS_MON" create configmap "$name" "$@" --dry-run=client -o yaml | kubectl apply -f -
}

echo
echo "== vmalert с правилами SLO (k8s/monitoring/rules/slo-rules.yaml)"
apply_configmap "$RULES_CONFIGMAP" --from-file="$ROOT/k8s/monitoring/rules/slo-rules.yaml"
helm upgrade --install "$VMALERT_RELEASE" "$HELM_REPO_NAME/victoria-metrics-alert" \
  --version "$VMALERT_CHART_VERSION" --namespace "$NS_MON" \
  --values "$ROOT/k8s/monitoring/vmalert-values.yaml" --wait --timeout 5m

echo
echo "== Grafana с дашбордом SLI/SLO/SLA"
# Пароль администратора — случайный, создаётся один раз и только в Secret:
# в values и в git его нет. Повторный деплой существующий Secret не трогает.
if ! kubectl -n "$NS_MON" get secret "$GRAFANA_SECRET" >/dev/null 2>&1; then
  password="$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(18))')"
  # printf — встроенная команда: пароль не попадает в аргументы процессов (ps).
  kubectl -n "$NS_MON" create secret generic "$GRAFANA_SECRET" \
    --from-literal=admin-user=admin \
    --from-file=admin-password=<(printf '%s' "$password")
  unset password
fi
apply_configmap "$DASHBOARDS_CONFIGMAP" --from-file="$ROOT/k8s/monitoring/dashboards/"
helm upgrade --install "$GRAFANA_RELEASE" "$GRAFANA_REPO_NAME/grafana" \
  --version "$GRAFANA_CHART_VERSION" --namespace "$NS_MON" \
  --values "$ROOT/k8s/monitoring/grafana-values.yaml" --wait --timeout 10m

echo
echo "== Приложение (namespace $NS_APP)"
kubectl apply -f "$ROOT/k8s/app/"
echo "Ждём PostgreSQL с экспортером..."
kubectl -n "$NS_APP" rollout status statefulset/db --timeout=180s
echo "Ждём приложение..."
kubectl -n "$NS_APP" rollout status deployment/taskflow --timeout=180s

echo
echo "== Пробер (namespace $NS_MON) — ходит в TaskFlow через Service, как клиент"
kubectl apply -f "$ROOT/k8s/monitoring/30-prober.yaml"
kubectl -n "$NS_MON" rollout status deployment/taskflow-prober --timeout=120s

echo
# kubectl apply не отменяет того, что сделал scripts/fault.sh (переменные
# FAULT_*, 0 реплик БД): этих полей нет в манифестах. Показываем, что внесено.
"$ROOT/scripts/fault.sh" status
echo
helm list -n "$NS_MON"
echo
kubectl get pods -n "$NS_MON"
echo
kubectl get pods -n "$NS_APP"
echo
echo "Туннели к VictoriaMetrics, vmalert и Grafana:  scripts/port-forward.sh"
echo "Пароль Grafana (пользователь admin):           scripts/grafana-password.sh"
echo "Текущие SLI, SLO и SLA:                        scripts/check-slo.sh"
echo "Внести сбой в приложение:                      scripts/fault.sh --help"
