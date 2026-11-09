#!/usr/bin/env bash
# Собирает архив для сдачи: отчёт, скринкаст и скриншоты, манифесты и values
# Helm-чартов, правила vmalert с тестами, дашборд Grafana, итоговые манифесты
# чартов (helm template), скрипты, исходники пробера и приложения с Dockerfile.
#
# Использование: scripts/make-archive.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

require_tools helm rsync python3

OUT="$ROOT/taskflow-sla.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/taskflow-sla"
mkdir -p "$DEST"

if [[ ! -f "$ROOT/screencast/screencast.mp4" ]]; then
  echo "Нет screencast/screencast.mp4 — сначала scripts/record-screencast.sh" >&2
  exit 1
fi
if ! ls "$ROOT/screenshots"/*.png >/dev/null 2>&1; then
  echo "В $ROOT/screenshots нет PNG — сначала scripts/screenshot-grafana.sh" >&2
  exit 1
fi

cp -R "$ROOT/k8s" "$ROOT/screenshots" "$ROOT/screencast" "$DEST/"
cp "$ROOT/Отчёт.md" "$ROOT/README.md" "$DEST/"

# Итоговые манифесты, которые Helm применил в кластер: те же чарты, версии и
# values, что в scripts/deploy.sh, — чтобы их можно было прочитать без Helm.
RENDERED="$DEST/k8s/monitoring/rendered"
mkdir -p "$RENDERED"
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" --force-update >/dev/null
helm repo add "$GRAFANA_REPO_NAME" "$GRAFANA_REPO_URL" --force-update >/dev/null
render() {
  local release="$1" chart="$2" version="$3" values="$4"
  helm template "$release" "$chart" --version "$version" --namespace "$NS_MON" \
    --values "$ROOT/k8s/monitoring/$values" > "$RENDERED/$release.yaml"
}
render "$VM_SINGLE_RELEASE" "$HELM_REPO_NAME/victoria-metrics-single" "$VM_SINGLE_CHART_VERSION" vmsingle-values.yaml
render "$VM_AGENT_RELEASE" "$HELM_REPO_NAME/victoria-metrics-agent" "$VM_AGENT_CHART_VERSION" vmagent-values.yaml
render "$VMALERT_RELEASE" "$HELM_REPO_NAME/victoria-metrics-alert" "$VMALERT_CHART_VERSION" vmalert-values.yaml
render "$GRAFANA_RELEASE" "$GRAFANA_REPO_NAME/grafana" "$GRAFANA_CHART_VERSION" grafana-values.yaml

# Скрипты и исходники с Dockerfile — чтобы образы собирались прямо из архива.
# Зависимости (их ставит npm ci), локальные файлы и отчёты других заданий не нужны.
EXCLUDES=(--exclude node_modules --exclude .git --exclude .env --exclude '*.log'
          --exclude .DS_Store --exclude 'Отчёт.md' --exclude '*.zip' --exclude coverage)
rsync -a "${EXCLUDES[@]}" "$ROOT/scripts/" "$DEST/scripts/"
rsync -a "${EXCLUDES[@]}" "$APP_DIR/" "$DEST/app/"
rsync -a "${EXCLUDES[@]}" "$PROBER_DIR/" "$DEST/prober/"

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
