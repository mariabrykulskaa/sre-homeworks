#!/usr/bin/env bash
# Собирает архив для сдачи: манифесты и values Helm-чартов, итоговые манифесты
# чартов (helm template), скрипты, отчёт со скриншотами, скринкаст и исходники
# приложения с Dockerfile.
#
# Использование: scripts/make-archive.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

OUT="$ROOT/taskflow-metrics.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/taskflow-metrics"
mkdir -p "$DEST"

if ! ls "$ROOT/screenshots"/*.png >/dev/null 2>&1; then
  echo "В $ROOT/screenshots нет PNG — отчёт без скриншотов сдавать нельзя" >&2
  exit 1
fi
if [[ ! -f "$ROOT/screencast/screencast.mp4" ]]; then
  echo "Нет screencast/screencast.mp4 — сначала scripts/record-screencast.sh" >&2
  exit 1
fi

cp -R "$ROOT/k8s" "$ROOT/scripts" "$ROOT/screenshots" "$ROOT/screencast" "$DEST/"
cp "$ROOT/Отчёт.md" "$ROOT/README.md" "$DEST/"

# Итоговые манифесты, которые Helm применил в кластер: те же чарты, версии и
# values, что в scripts/deploy.sh, — чтобы их можно было прочитать без Helm.
RENDERED="$DEST/k8s/monitoring/rendered"
mkdir -p "$RENDERED"
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" --force-update >/dev/null
helm template "$VM_SINGLE_RELEASE" "$HELM_REPO_NAME/victoria-metrics-single" \
  --version "$VM_SINGLE_CHART_VERSION" --namespace "$NS_MON" \
  --values "$ROOT/k8s/monitoring/vmsingle-values.yaml" > "$RENDERED/vm-single.yaml"
helm template "$VM_AGENT_RELEASE" "$HELM_REPO_NAME/victoria-metrics-agent" \
  --version "$VM_AGENT_CHART_VERSION" --namespace "$NS_MON" \
  --values "$ROOT/k8s/monitoring/vmagent-values.yaml" > "$RENDERED/vm-agent.yaml"

# Исходники приложения вместе с Dockerfile — чтобы образ собирался прямо из
# архива. Зависимости, локальные файлы и отчёты других заданий не нужны.
rsync -a \
  --exclude node_modules --exclude .git --exclude .env --exclude '*.log' \
  --exclude .DS_Store --exclude 'Отчёт.md' --exclude '*.zip' --exclude __pycache__ --exclude .pytest_cache --exclude .venv \
  "$APP_DIR/" "$DEST/app/"

rm -f "$OUT"
# zip на macOS не ставит флаг UTF-8 в именах, и «Отчёт.md» на Windows
# распаковался бы с искажённым именем; zipfile в Python этот флаг ставит.
python3 -I - "$STAGE" "$OUT" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirnames, filenames in os.walk(stage):
        dirnames.sort()
        for name in sorted(filenames):
            if name == ".DS_Store":
                continue
            full = os.path.join(dirpath, name)
            z.write(full, os.path.relpath(full, stage))
PY

echo "Готово: $OUT"
python3 -I -c 'import sys, zipfile; [print(i.file_size, i.filename) for i in zipfile.ZipFile(sys.argv[1]).infolist()]' "$OUT"
