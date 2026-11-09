"""Общие помощники обработчиков: тело запроса, параметры строки запроса, JSON-ответ."""

import json
from datetime import datetime, timezone
from typing import Any

from fastapi import Request

from ..errors import HttpError

MAX_BODY_BYTES = 100 * 1024


async def read_json(request: Request) -> Any:
    """Тело запроса как JSON. Не JSON по Content-Type — тела нет (None):
    тогда проверка вернёт 400 «Request body must be a JSON object»."""
    raw = await request.body()
    if len(raw) > MAX_BODY_BYTES:
        raise HttpError(413, "Request body too large")
    content_type = request.headers.get("content-type", "")
    if "json" not in content_type.split(";", 1)[0].lower():
        return None
    if raw.strip() == b"":
        return {}
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise HttpError(400, "Invalid JSON body") from None


def query_params(request: Request) -> dict:
    """Параметры строки запроса; повторённый параметр (?limit=1&limit=2) — списком,
    чтобы проверка его отклонила, а не взяла молча первое значение."""
    out: dict = {}
    for key in request.query_params.keys():
        values = request.query_params.getlist(key)
        out[key] = values[0] if len(values) == 1 else values
    return out


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def serialize(row: dict) -> dict:
    """Строка БД → JSON API. Идентификаторы BIGINT отдаются строками ("7"),
    как в прошлых версиях API: фронтенд сравнивает их со строками из data-id."""
    out = {}
    for key, value in row.items():
        if key in ("id", "project_id") and value is not None:
            out[key] = str(value)
        elif isinstance(value, datetime):
            out[key] = _iso(value)
        else:
            out[key] = value
    return out
