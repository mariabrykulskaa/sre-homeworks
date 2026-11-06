#!/usr/bin/env bash
# Собирает архив для сдачи: манифесты, конфигурацию шиппера, скрипты, отчёт
# со скриншотами и исходники приложения с Dockerfile.
#
# Использование: scripts/make-archive.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

OUT="$ROOT/taskflow-logging.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/taskflow-logging"
mkdir -p "$DEST"

if [[ ! -d "$ROOT/screenshots" ]] || ! ls "$ROOT/screenshots"/*.png >/dev/null 2>&1; then
  echo "В $ROOT/screenshots нет PNG — отчёт без скриншотов сдавать нельзя" >&2
  exit 1
fi

cp -R "$ROOT/k8s" "$ROOT/scripts" "$ROOT/screenshots" "$DEST/"
cp "$ROOT/Отчёт.md" "$ROOT/README.md" "$DEST/"

# Исходники приложения вместе с Dockerfile — чтобы образ собирался прямо из
# архива. Зависимости, локальные файлы и отчёты других заданий не нужны.
rsync -a \
  --exclude node_modules --exclude .git --exclude .env --exclude '*.log' \
  --exclude .DS_Store --exclude 'Отчёт.md' --exclude '*.zip' \
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
