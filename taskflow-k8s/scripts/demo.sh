#!/usr/bin/env bash
# Терминальная часть скринкаста ДЗ №2 (её записывает scripts/record-screencast.sh):
# запуск приложения и зависимостей, вывод подов, масштабирование.
# Команды настоящие, вывод — живой; «печать» команд замедлена для читаемости.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

BOLD=$'\e[1m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; RESET=$'\e[0m'
TYPE_DELAY="${TYPE_DELAY:-0.02}"

say() { printf '\n%s# %s%s\n' "$BOLD$CYAN" "$1" "$RESET"; sleep 0.8; }
run() {
  local cmd="$1" i
  printf '%s$ %s' "$GREEN" "$RESET"
  for ((i = 0; i < ${#cmd}; i++)); do
    printf '%s' "${cmd:i:1}"
    sleep "$TYPE_DELAY"
  done
  printf '\n'
  bash -o pipefail -c "$cmd" || true
  sleep 1.5
}

cd "$ROOT"
clear
say "ДЗ №2: TaskFlow (Python + FastAPI) и PostgreSQL в minikube"
run "kubectl get nodes"
run "minikube image ls | grep -E '(^|/)taskflow:'"
run "ls k8s/"

say "Запуск приложения и зависимостей"
run "kubectl apply -f k8s/"

say "Поды: db-0 (StatefulSet), taskflow-* (Deployment; init-контейнеры wait-for-db и migrate)"
run "kubectl get pods -n taskflow"
run "kubectl rollout status statefulset/db -n taskflow --timeout=180s"
run "kubectl rollout status deployment/taskflow -n taskflow --timeout=180s"
run "kubectl get pods -n taskflow -o wide"
run "kubectl get all,pvc -n taskflow"
run "kubectl logs -n taskflow deploy/taskflow -c migrate --tail=3"

say "Масштабирование: 2 → 4 реплики"
run "kubectl scale deployment/taskflow -n taskflow --replicas=4"
run "kubectl rollout status deployment/taskflow -n taskflow --timeout=180s"
run "kubectl get pods -n taskflow -o wide"
run "kubectl get endpointslices -n taskflow -l kubernetes.io/service-name=taskflow"

say "UI: туннель до Service taskflow (на macOS NodePort снаружи недоступен) → http://localhost:8080"
printf '%s$ %s%s\n' "$GREEN" "$RESET" "kubectl port-forward svc/taskflow -n taskflow 8080:80"
sleep 2
