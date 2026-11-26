#!/usr/bin/env bash
# Собирает архив для сдачи taskflow-deploy.zip: отчёт, манифесты, скрипты,
# видео и логи каждой стратегии, исходники приложения с Dockerfile.
# Общее видео all-strategies.mp4 не кладётся — оно дублирует пять отдельных.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

for name in 1-rolling 2-blue-green 3-canary 4-ab-testing 5-shadow; do
  for f in "screencast/$name.mp4" "logs/$name.terminal.log" "logs/$name.envoy.log" "logs/$name.app.log"; do
    [[ -f "$ROOT/$f" ]] || { echo "Нет $f — сначала scripts/record.sh" >&2; exit 1; }
  done
done

OUT="$ROOT/../taskflow-deploy.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/taskflow-deploy"
mkdir -p "$DEST/screencast"

cp "$ROOT/Отчёт.md" "$ROOT/README.md" "$DEST/"
cp -R "$ROOT/k8s" "$ROOT/logs" "$DEST/"
rsync -a --exclude __pycache__ "$ROOT/scripts/" "$DEST/scripts/"
cp "$ROOT"/screencast/[1-5]-*.mp4 "$ROOT"/screencast/[1-5]-*.cast "$DEST/screencast/"
rsync -a \
  --exclude node_modules --exclude .git --exclude .env --exclude '*.log' --exclude .DS_Store \
  --exclude '*.zip' --exclude __pycache__ --exclude .pytest_cache --exclude .venv \
  "$APP_DIR/" "$DEST/app/"

rm -f "$OUT"
# zipfile из Python ставит флаг UTF-8 в именах — «Отчёт.md» распакуется верно и в Windows.
python3 -I - "$STAGE" "$OUT" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirnames, filenames in os.walk(stage):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            z.write(full, os.path.relpath(full, stage))
PY

echo "Готово: $(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
python3 -I -c 'import os, sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); print(len(z.infolist()), "файлов,", round(os.path.getsize(sys.argv[1]) / 2**20, 1), "МБ")' "$OUT"
