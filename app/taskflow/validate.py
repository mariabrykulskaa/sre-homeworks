"""Проверка входных данных — «охранник на входе».

Всё, что прислал клиент, проверяется до похода в БД; плохие данные дают 400 с
понятным сообщением. Те же ограничения продублированы в схеме БД (CHECK, FK,
NOT NULL) — последняя линия защиты на случай записи в обход API.
"""

import re
from typing import Any

from .errors import HttpError
from .metrics import TASK_STATUSES

# До 15 цифр — заведомо в пределах BIGINT; без нуля и ведущих нулей.
_ID = re.compile(r"^[1-9]\d{0,14}$")
_OFFSET = re.compile(r"^\d{1,15}$")


def parse_id(raw: Any, name: str = "id") -> int:
    if isinstance(raw, bool) or not _ID.match(str(raw)):
        raise HttpError(400, f"{name} must be a positive integer")
    return int(raw)


def parse_pagination(query: dict, default_limit: int = 100, max_limit: int = 500, max_offset: int = 100_000) -> tuple[int, int]:
    """query — словарь параметров; повторённый параметр приходит списком и отклоняется."""
    limit, offset = default_limit, 0
    if query.get("limit") is not None:
        limit = min(parse_id(query["limit"], "limit"), max_limit)
    if query.get("offset") is not None:
        if not _OFFSET.match(str(query["offset"])):
            raise HttpError(400, "offset must be a non-negative integer")
        offset = int(query["offset"])
        # Огромный OFFSET заставляет СУБД сканировать и выбрасывать строки.
        if offset > max_offset:
            raise HttpError(400, f"offset must be at most {max_offset}")
    return limit, offset


def _require_object(body: Any) -> None:
    if not isinstance(body, dict):
        raise HttpError(400, "Request body must be a JSON object")


def _clean_string(value: Any, field: str, *, required: bool, max_length: int) -> str | None:
    """Единая политика: явный null эквивалентен отсутствию поля."""
    if value is None:
        if required:
            raise HttpError(400, f'"{field}" is required')
        return None
    if not isinstance(value, str):
        raise HttpError(400, f'"{field}" must be a string')
    trimmed = value.strip()
    if "\x00" in trimmed:
        raise HttpError(400, f'"{field}" must not contain NUL characters')
    try:
        # Одинокие суррогаты (\ud800) не кодируются в UTF-8 и не запишутся в БД.
        trimmed.encode("utf-8")
    except UnicodeEncodeError:
        raise HttpError(400, f'"{field}" must be well-formed Unicode') from None
    if required and trimmed == "":
        raise HttpError(400, f'"{field}" must not be empty')
    # len() в Python считает символы (code points) — как char_length() в PostgreSQL.
    if len(trimmed) > max_length:
        raise HttpError(400, f'"{field}" must be at most {max_length} characters')
    return trimmed


def _require_any_field(entity: dict) -> None:
    if all(value is None for value in entity.values()):
        raise HttpError(400, "No fields to update")


def validate_project(body: Any, partial: bool = False) -> dict:
    """partial=True — для изменения (PUT): отсутствующие поля не трогаем."""
    _require_object(body)
    project = {
        "name": _clean_string(body.get("name"), "name", required=not partial, max_length=120),
        "description": _clean_string(body.get("description"), "description", required=False, max_length=2000),
    }
    if partial and project["name"] == "":
        raise HttpError(400, '"name" must not be empty')
    if partial:
        _require_any_field(project)
    return project


def validate_task(body: Any, partial: bool = False) -> dict:
    _require_object(body)
    task = {
        "title": _clean_string(body.get("title"), "title", required=not partial, max_length=200),
        "description": _clean_string(body.get("description"), "description", required=False, max_length=5000),
        "status": None,
        "project_id": None,
    }
    if partial and task["title"] == "":
        raise HttpError(400, '"title" must not be empty')
    status = body.get("status")
    if status is not None:
        if status not in TASK_STATUSES:
            raise HttpError(400, f'"status" must be one of: {", ".join(TASK_STATUSES)}')
        task["status"] = status
    project_id = body.get("project_id")
    if project_id is not None:
        task["project_id"] = parse_id(project_id, "project_id")
    elif not partial:
        raise HttpError(400, '"project_id" is required')
    if partial:
        _require_any_field(task)
    return task
