# Общие переменные для скриптов. Подключается через `source`.
# shellcheck disable=SC2034  # переменные используются в скриптах, которые подключают этот файл
#
# Исходники приложения: в распакованном архиве они лежат в ./app,
# в репозитории — в ../app (одна кодовая база для всех ДЗ).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS_APP=taskflow
NS_LOG=logging
IMAGE_DEFAULT=taskflow:2.0
# Локальный порт для kubectl port-forward до Victoria Logs (vmui и API).
VL_LOCAL_PORT="${VL_LOCAL_PORT:-9428}"
VL_URL="${VL_URL:-http://127.0.0.1:${VL_LOCAL_PORT}}"
# Бонус: vmalert и Alertmanager (UI тоже через port-forward).
VMALERT_LOCAL_PORT="${VMALERT_LOCAL_PORT:-8880}"
VMALERT_URL="${VMALERT_URL:-http://127.0.0.1:${VMALERT_LOCAL_PORT}}"
AM_LOCAL_PORT="${AM_LOCAL_PORT:-9093}"
AM_URL="${AM_URL:-http://127.0.0.1:${AM_LOCAL_PORT}}"

if [[ -z "${APP_DIR:-}" ]]; then
  if [[ -f "$ROOT/app/Dockerfile" ]]; then
    APP_DIR="$ROOT/app"
  else
    APP_DIR="$ROOT/../app"
  fi
fi
