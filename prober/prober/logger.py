"""JSON-логи пробера: та же схема, что у TaskFlow (одна строка — одно событие, stdout)."""

import json
import os
import sys
import traceback
from datetime import datetime, timezone

from . import __version__

LEVELS = ("debug", "info", "warn", "error")


class Logger:
    def __init__(self, level: str | None = None, stream=None, bindings: dict | None = None) -> None:
        level = (level if level is not None else os.environ.get("LOG_LEVEL", "")).strip().lower() or "info"
        if level not in LEVELS:
            raise ValueError(f'LOG_LEVEL must be one of: {", ".join(LEVELS)}, got "{level}"')
        self.level = level
        self._stream = stream
        self._bindings = bindings or {}

    def _write(self, level: str, message: str, fields: dict) -> None:
        if LEVELS.index(level) < LEVELS.index(self.level):
            return
        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": level,
            "message": message,
            "service.name": os.environ.get("SERVICE_NAME", "taskflow-prober"),
            "service.version": __version__,
            "deployment.environment": os.environ.get("APP_ENV", "production"),
            **self._bindings,
        }
        for key, value in fields.items():
            if value is None:
                continue
            if isinstance(value, BaseException):
                record[f"{key}.message"] = str(value)
                record[f"{key}.type"] = type(value).__name__
                record[f"{key}.stack"] = "".join(traceback.format_exception(value)).rstrip()
            else:
                record[key] = value
        stream = self._stream or sys.stdout
        stream.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
        stream.flush()

    def debug(self, message: str, **fields) -> None:
        self._write("debug", message, fields)

    def info(self, message: str, **fields) -> None:
        self._write("info", message, fields)

    def warn(self, message: str, **fields) -> None:
        self._write("warn", message, fields)

    def error(self, message: str, **fields) -> None:
        self._write("error", message, fields)
