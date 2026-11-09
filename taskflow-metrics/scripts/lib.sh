# shellcheck shell=bash
# Общие переменные для скриптов. Подключается через `source`.
# shellcheck disable=SC2034  # переменные используются в скриптах, которые подключают этот файл
#
# Исходники приложения: в распакованном архиве они лежат в ./app,
# в репозитории — в ../app (одна кодовая база для всех ДЗ).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS_APP=taskflow
NS_MON=monitoring
IMAGE_DEFAULT=taskflow:2.0

# Helm: репозиторий и версии чартов закреплены — повторный деплой ставит то же самое.
HELM_REPO_NAME=vm
HELM_REPO_URL=https://victoriametrics.github.io/helm-charts/
VM_SINGLE_RELEASE=vm-single
VM_SINGLE_CHART_VERSION=0.49.0   # VictoriaMetrics v1.154.0
VM_AGENT_RELEASE=vm-agent
VM_AGENT_CHART_VERSION=0.50.0    # vmagent v1.154.0
# Имена Service'ов (такие же, как в командах проверки из задания).
VM_SINGLE_SVC=vm-single-victoria-metrics-single-server
VM_AGENT_SVC=vm-single-victoria-metrics-agent

# Локальные порты для kubectl port-forward.
VM_LOCAL_PORT="${VM_LOCAL_PORT:-8428}"
VM_URL="${VM_URL:-http://127.0.0.1:${VM_LOCAL_PORT}}"
VMAGENT_LOCAL_PORT="${VMAGENT_LOCAL_PORT:-8429}"
VMAGENT_URL="${VMAGENT_URL:-http://127.0.0.1:${VMAGENT_LOCAL_PORT}}"

if [[ -z "${APP_DIR:-}" ]]; then
  if [[ -f "$ROOT/app/Dockerfile" ]]; then
    APP_DIR="$ROOT/app"
  else
    APP_DIR="$ROOT/../app"
  fi
fi
