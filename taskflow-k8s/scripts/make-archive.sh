#!/usr/bin/env bash
# Собирает архив для сдачи: манифесты, исходники приложения с Dockerfile,
# отчёт, скрипты и скринкаст.
#
# Использование: scripts/make-archive.sh [путь/к/скринкасту.mp4]   (по умолчанию screencast/screencast.mp4)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

SCREENCAST="${1:-$ROOT/screencast/screencast.mp4}"
if [[ ! -f "$SCREENCAST" ]]; then
  echo "Нет скринкаста $SCREENCAST — сначала scripts/record-screencast.sh (файл требует задание)" >&2
  exit 1
fi

OUT="$ROOT/taskflow-k8s.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/taskflow-k8s"
mkdir -p "$DEST"

cp -R "$ROOT/k8s" "$DEST/"
rsync -a --exclude node_modules "$ROOT/scripts/" "$DEST/scripts/"
mkdir -p "$DEST/screencast"
cp "$ROOT/Отчёт.md" "$ROOT/README.md" "$DEST/"
cp "$SCREENCAST" "$DEST/screencast/screencast.mp4"

# Исходники приложения вместе с Dockerfile — чтобы образ собирался прямо из
# архива. Отчёт первого задания, зависимости и локальные файлы не нужны.
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
            full = os.path.join(dirpath, name)
            z.write(full, os.path.relpath(full, stage))
PY

echo "Готово: $OUT"
python3 -I -c 'import sys, zipfile; [print(i.file_size, i.filename) for i in zipfile.ZipFile(sys.argv[1]).infolist()]' "$OUT"
