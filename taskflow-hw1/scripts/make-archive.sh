#!/usr/bin/env bash
# Собирает архив для сдачи ДЗ №1: исходный код приложения (../app) и отчёт.
# Использование: scripts/make-archive.sh   → taskflow-hw1.zip рядом с отчётом
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${APP_DIR:-$ROOT/../app}"
OUT="$ROOT/taskflow-hw1.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/taskflow-hw1"
mkdir -p "$DEST"

# Исходники — в корень архива: «docker compose up» работает сразу после распаковки.
rsync -a --exclude .git --exclude .env --exclude __pycache__ --exclude .pytest_cache \
  --exclude .venv --exclude .DS_Store "$APP_DIR/" "$DEST/"
cp "$ROOT/Отчёт.md" "$DEST/"
# В архиве исходники лежат рядом с отчётом, а не в ../app.
python3 -I - "$DEST/Отчёт.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
for old, new in [
    ("Исходный код — [../app](../app) (Python), инструкция по запуску — [../app/README.md](../app/README.md).",
     "Исходный код (Python) — в этом архиве, инструкция по запуску — [README.md](README.md)."),
    ("[`app/README.md`](../app/README.md)", "[`README.md`](README.md)"),
    ("(../app/", "("),
    ("cd ../app\n", ""),
    ("см. app/README.md", "см. README.md"),
]:
    s = s.replace(old, new)
open(p, "w", encoding="utf-8").write(s)
PY

rm -f "$OUT"
# zipfile из Python ставит флаг UTF-8 в именах — «Отчёт.md» распакуется корректно и на Windows.
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
