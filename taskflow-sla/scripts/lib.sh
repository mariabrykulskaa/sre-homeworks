# shellcheck shell=bash
# Общие переменные для скриптов. Подключается через `source`.
# shellcheck disable=SC2034  # переменные используются в скриптах, которые подключают этот файл
#
# Исходники приложения: в распакованном архиве они лежат в ./app,
# в репозитории — в ../app и ../prober (одна кодовая база для всех ДЗ).
# Пробер — в ./prober (архив) или ../prober (репозиторий).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS_APP=taskflow
NS_MON=monitoring
APP_IMAGE=taskflow:2.0
PROBER_IMAGE=taskflow-prober:2.0
PROBER_DIR="${PROBER_DIR:-$([[ -f "$ROOT/prober/Dockerfile" ]] && echo "$ROOT/prober" || echo "$ROOT/../prober")}"

# Helm: репозитории и версии чартов закреплены — повторный деплой ставит то же самое.
HELM_REPO_NAME=vm
HELM_REPO_URL=https://victoriametrics.github.io/helm-charts/
VM_SINGLE_RELEASE=vm-single
VM_SINGLE_CHART_VERSION=0.49.0   # VictoriaMetrics v1.154.0
VM_AGENT_RELEASE=vm-agent
VM_AGENT_CHART_VERSION=0.50.0    # vmagent v1.154.0
VMALERT_RELEASE=vmalert
VMALERT_CHART_VERSION=0.51.0     # vmalert v1.154.0
# Чарт grafana/grafana заморожен на Grafana 12; развивается его форк в grafana-community.
GRAFANA_REPO_NAME=grafana-community
GRAFANA_REPO_URL=https://grafana-community.github.io/helm-charts
GRAFANA_RELEASE=grafana
GRAFANA_CHART_VERSION=14.1.0     # Grafana 13.2.4
# Имена Service'ов (fullnameOverride в values — короткие и предсказуемые).
VM_SINGLE_SVC=vm-single-victoria-metrics-single-server
VM_AGENT_SVC=vm-single-victoria-metrics-agent
VMALERT_SVC=vmalert
GRAFANA_SVC=grafana
# ConfigMap'ы, которые деплой собирает из файлов репозитория.
RULES_CONFIGMAP=vmalert-slo-rules
DASHBOARDS_CONFIGMAP=grafana-dashboards-slo
GRAFANA_SECRET=grafana-admin
# Образ для проверки правил (vmalert-tool unittest) — той же версии, что vmalert.
VMALERT_TOOL_IMAGE=victoriametrics/vmalert-tool:v1.154.0

# Локальные порты для kubectl port-forward.
VM_LOCAL_PORT="${VM_LOCAL_PORT:-8428}"
VM_URL="${VM_URL:-http://127.0.0.1:${VM_LOCAL_PORT}}"
VMAGENT_LOCAL_PORT="${VMAGENT_LOCAL_PORT:-8429}"
VMAGENT_URL="${VMAGENT_URL:-http://127.0.0.1:${VMAGENT_LOCAL_PORT}}"
VMALERT_LOCAL_PORT="${VMALERT_LOCAL_PORT:-8880}"
VMALERT_URL="${VMALERT_URL:-http://127.0.0.1:${VMALERT_LOCAL_PORT}}"
GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3000}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:${GRAFANA_LOCAL_PORT}}"

if [[ -z "${APP_DIR:-}" ]]; then
  if [[ -f "$ROOT/app/Dockerfile" ]]; then
    APP_DIR="$ROOT/app"
  else
    APP_DIR="$ROOT/../app"
  fi
fi

# require_tools инструмент... — выходит с понятной ошибкой, если чего-то нет в PATH.
require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || { echo "Не найден $tool" >&2; exit 1; }
  done
}

# require_tunnel URL ИМЯ — проверяет, что туннель scripts/port-forward.sh поднят.
require_tunnel() {
  if ! curl -fsS -o /dev/null --max-time 3 "$1"; then
    echo "Нет ответа от $2 ($1) — запущен ли scripts/port-forward.sh?" >&2
    exit 1
  fi
}

DASHBOARD_PATH="/d/taskflow-slo"

# ensure_node_deps — ставит зависимости scripts/*.mjs (playwright-core из
# scripts/package.json, версия закреплена в package-lock.json) в
# scripts/node_modules, если их ещё нет. Браузер не скачивается: используется
# установленный Google Chrome. --ignore-scripts — пакеты ничего не запускают.
ensure_node_deps() {
  require_tools node npm
  if [[ ! -d "$ROOT/scripts/node_modules/playwright-core" ]]; then
    npm ci --prefix "$ROOT/scripts" --ignore-scripts --no-audit --no-fund
  fi
}

# export_grafana_credentials — логин и пароль Grafana из Secret в переменные
# окружения для scripts/*.mjs (в аргументах команд их видно в `ps`).
export_grafana_credentials() {
  GRAFANA_USER="$(kubectl -n "$NS_MON" get secret "$GRAFANA_SECRET" -o jsonpath='{.data.admin-user}' | base64 --decode)"
  GRAFANA_PASSWORD="$(kubectl -n "$NS_MON" get secret "$GRAFANA_SECRET" -o jsonpath='{.data.admin-password}' | base64 --decode)"
  if [[ -z "$GRAFANA_USER" || -z "$GRAFANA_PASSWORD" ]]; then
    echo "Нет логина или пароля в Secret $NS_MON/$GRAFANA_SECRET — запускался ли scripts/deploy.sh?" >&2
    exit 1
  fi
  export GRAFANA_USER GRAFANA_PASSWORD
}
