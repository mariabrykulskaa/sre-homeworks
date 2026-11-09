"""XI. Логи — поток событий: одна строка JSON на событие, только в stdout.

Сбор, доставка и хранение логов — забота окружения (в Kubernetes: kubelet →
Vector → Victoria Logs); приложение их никуда не пишет и не ротирует.

Схема записи (общие поля есть у каждой строки):
  timestamp              RFC 3339 с миллисекундами, UTC
  level                  debug | info | warn | error
  message                короткое событие в неизменной формулировке (для поиска)
  service.name           имя сервиса (SERVICE_NAME, по умолчанию taskflow)
  service.version        версия приложения
  deployment.environment APP_ENV
Остальные поля — контекст события (method, path, status, duration_ms, error.* …).
Вложенные объекты не используются: плоские имена через точку одинаково удобны
человеку, Victoria Logs и Grafana.
"""

import json
import logging
import os
import sys
import traceback
from datetime import datetime, timezone
from typing import Any, Callable, TextIO

from . import __version__

LOG_LEVELS = ("debug", "info", "warn", "error")

# Эти ключи задаёт сам логгер; поля вызывающего кода их не перетирают.
_RESERVED = {"timestamp", "level", "message", "service.name", "service.version", "deployment.environment"}


def _flatten_error(prefix: str, err: BaseException) -> dict:
    out = {
        f"{prefix}.message": str(err),
        f"{prefix}.stack": "".join(traceback.format_exception(err)).rstrip(),
    }
    code = getattr(err, "code", None) or getattr(err, "sqlstate", None)
    if code is not None:
        out[f"{prefix}.code"] = code
    out[f"{prefix}.type"] = type(err).__name__
    return out


def _normalize(fields: dict) -> dict:
    out: dict = {}
    for key, value in fields.items():
        if value is None or key in _RESERVED:
            continue
        if isinstance(value, BaseException):
            out.update(_flatten_error(key, value))
        else:
            out[key] = value
    return out


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class Logger:
    def __init__(
        self,
        *,
        service: str | None = None,
        version: str = __version__,
        env: str | None = None,
        level: str | None = None,
        stream: TextIO | None = None,
        now: Callable[[], str] = _now_iso,
        bindings: dict | None = None,
    ) -> None:
        level = (level if level is not None else os.environ.get("LOG_LEVEL", "")).strip().lower() or "info"
        if level not in LOG_LEVELS:
            raise ValueError(f'LOG_LEVEL must be one of: {", ".join(LOG_LEVELS)}, got "{level}"')
        self.service = service or os.environ.get("SERVICE_NAME") or "taskflow"
        self.version = version
        self.env = env or os.environ.get("APP_ENV", "development")
        self.level = level
        self._threshold = LOG_LEVELS.index(level)
        self._stream = stream
        self._now = now
        self._base = _normalize(bindings or {})

    def _write(self, level: str, message: str, fields: dict) -> None:
        if LOG_LEVELS.index(level) < self._threshold:
            return
        head = {
            "timestamp": self._now(),
            "level": level,
            "message": str(message),
            "service.name": self.service,
            "service.version": self.version,
            "deployment.environment": self.env,
        }
        try:
            line = json.dumps({**head, **self._base, **_normalize(fields)}, ensure_ascii=False, default=str)
        except (TypeError, ValueError) as err:
            # Непредставимое значение в контексте — не повод терять событие.
            line = json.dumps({**head, "logger.error": str(err)}, ensure_ascii=False)
        stream = self._stream or sys.stdout
        stream.write(line + "\n")
        stream.flush()

    def debug(self, message: str, **fields: Any) -> None:
        self._write("debug", message, fields)

    def info(self, message: str, **fields: Any) -> None:
        self._write("info", message, fields)

    def warn(self, message: str, **fields: Any) -> None:
        self._write("warn", message, fields)

    def error(self, message: str, **fields: Any) -> None:
        self._write("error", message, fields)

    def child(self, **extra: Any) -> "Logger":
        """Дочерний логгер с постоянным контекстом (например, request_id)."""
        return Logger(
            service=self.service, version=self.version, env=self.env, level=self.level,
            stream=self._stream, now=self._now, bindings={**self._base, **extra},
        )


class _ForwardHandler(logging.Handler):
    """Сообщения библиотек (uvicorn, psycopg) — в тот же JSON-поток."""

    _LEVELS = {logging.DEBUG: "debug", logging.INFO: "info", logging.WARNING: "warn"}

    def __init__(self, target: Logger) -> None:
        super().__init__()
        self._target = target

    def emit(self, record: logging.LogRecord) -> None:
        level = self._LEVELS.get(record.levelno, "error")
        fields: dict = {"logger": record.name}
        if record.exc_info and record.exc_info[1] is not None:
            fields["error"] = record.exc_info[1]
        self._target._write(level, record.getMessage(), fields)


def route_stdlib_logging(target: Logger) -> None:
    """Перенаправляет стандартный logging в JSON-логгер: никаких текстовых строк в stdout."""
    root = logging.getLogger()
    root.handlers[:] = [_ForwardHandler(target)]
    root.setLevel(logging.WARNING)
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        lg = logging.getLogger(name)
        lg.handlers[:] = []
        lg.propagate = True


# Общий экземпляр приложения. Настраивается только окружением (III фактор):
# SERVICE_NAME, APP_ENV, LOG_LEVEL (debug | info | warn | error, по умолчанию info).
logger = Logger()
