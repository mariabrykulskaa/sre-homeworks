# Общие переменные для скриптов. Подключается через `source`.
# shellcheck disable=SC2034  # переменные используются в скриптах, которые подключают этот файл
#
# Исходники приложения: в распакованном архиве они лежат в ./app,
# в репозитории — в ../app (одна кодовая база для всех ДЗ).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=taskflow
IMAGE_DEFAULT=taskflow:2.0

if [[ -z "${APP_DIR:-}" ]]; then
  if [[ -f "$ROOT/app/Dockerfile" ]]; then
    APP_DIR="$ROOT/app"
  else
    APP_DIR="$ROOT/../app"
  fi
fi
