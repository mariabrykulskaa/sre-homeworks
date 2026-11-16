#!/usr/bin/env python3
"""Package the homework and application sources, excluding local dependencies."""
from pathlib import Path
import os
import zipfile

root = Path(__file__).resolve().parents[1]
archive = root.parent / 'taskflow-grafana.zip'
excluded = {'node_modules', '.git', '.venv', 'venv', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.frames'}
required = ['Отчёт.md', 'dashboards/taskflow-overview.json', 'dashboards/postgresql-exporter.json',
            'screencast/screencast.mp4', 'screenshots/01-application-red.png',
            'screenshots/02-python-runtime.png', 'screenshots/03-prober-sla.png',
            'screenshots/04-postgresql-overview.png', 'screenshots/05-postgresql-database.png',
            'evidence/dashboard-queries.json']
for name in required:
    if not (root / name).is_file():
        raise SystemExit(f'Нет обязательного артефакта: {name}')
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for source, prefix in [(root, Path(root.name)), (root.parent / 'app', Path(root.name) / 'app'),
                           (root.parent / 'prober', Path(root.name) / 'prober')]:
        if not source.is_dir():
            source = root / prefix.name
        for current, dirs, files in os.walk(source):
            dirs[:] = sorted(d for d in dirs if d not in excluded and not (Path(current) / d).is_symlink())
            if source == root and Path(current) == root:
                dirs[:] = [d for d in dirs if d not in ('app', 'prober')]
            for name in sorted(files):
                full = Path(current) / name
                if full.is_symlink() or name == '.DS_Store' or name.endswith(('.zip', '.pyc', '.webm')):
                    continue
                if (name == '.env' or name.startswith('.env.')) and name != '.env.example':
                    continue
                z.write(full, prefix / full.relative_to(source))
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    for name in required:
        assert f'{root.name}/{name}' in z.namelist()
    print(f'{archive}\n{len(z.namelist())} файлов · {archive.stat().st_size / 1024 / 1024:.2f} MiB · проверка CRC: OK')
