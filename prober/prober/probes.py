"""Пробы — синтетические сценарии пользователя TaskFlow через публичный API.

Пробер знает о приложении только то, что знает любой клиент: адрес и контракт
REST API. Поэтому он видит сбой так же, как пользователь, — в том числе когда
до приложения запрос не доходит вовсе (нет готовых реплик за Service), а
серверные метрики молчат.

Проба — последовательность шагов; первый неуспешный шаг обрывает её. Причина
неуспеха (reason) — метка в метриках:
  timeout            ответа нет за REQUEST_TIMEOUT_MS
  connection         соединение не установлено или оборвано
  server_error       ответ 5xx
  unexpected_status  другой неожиданный статус (например, 404 вместо 201)
  invalid_body       ответ не JSON или не тот, что обещает API
"""

import asyncio
import json
import re
import uuid
from dataclasses import dataclass
from typing import Awaitable, Callable

import httpx

from . import __version__

USER_AGENT = f"taskflow-prober/{__version__}"
# Ответы API TaskFlow — килобайты; больше — явно не тот ответ.
MAX_BODY_BYTES = 1024 * 1024
_ID = re.compile(r"^[1-9]\d*$")


class ProbeFailure(Exception):
    def __init__(self, step: str, reason: str, message: str, status: int | None = None, request_id: str | None = None):
        super().__init__(message)
        self.step = step
        self.reason = reason
        self.status = status
        self.request_id = request_id


def is_id(value) -> bool:
    """Идентификаторы TaskFlow — BIGINT, в JSON приходят строками ("7")."""
    return isinstance(value, str) and bool(_ID.match(value))


def check(step: str, condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(step, "invalid_body", message)


def new_client(transport: httpx.AsyncBaseTransport | None = None) -> httpx.AsyncClient:
    """HTTP-клиент без keep-alive: каждый запрос — новое TCP-соединение.

    Service Kubernetes балансирует соединения, а не запросы. С keep-alive все
    пробы шли бы по одному соединению в одну реплику, и сбой второй реплики
    пробер бы не увидел.
    """
    return httpx.AsyncClient(
        transport=transport,
        limits=httpx.Limits(max_keepalive_connections=0),
        timeout=None,  # общий таймаут запроса — asyncio.wait_for ниже
        follow_redirects=False,
    )


async def send(client: httpx.AsyncClient, method: str, url: str, *, timeout_ms: int, body=None, headers=None):
    """Один запрос. Возвращает (status, text) или бросает (reason, message)."""

    async def do():
        request = client.build_request(
            method, url, json=body,
            headers={"accept": "application/json", "user-agent": USER_AGENT, **(headers or {})},
        )
        response = await client.send(request, stream=True)
        try:
            chunks, size = [], 0
            async for chunk in response.aiter_bytes():
                size += len(chunk)
                if size > MAX_BODY_BYTES:
                    raise _RequestError("invalid_body", f"response body exceeds {MAX_BODY_BYTES} bytes")
                chunks.append(chunk)
            return response.status_code, b"".join(chunks).decode("utf-8", "replace")
        finally:
            await response.aclose()

    try:
        return await asyncio.wait_for(do(), timeout_ms / 1000)
    except asyncio.TimeoutError:
        raise _RequestError("timeout", f"no response within {timeout_ms} ms") from None
    except httpx.TransportError as err:
        # Нет готовых реплик за Service, DNS, обрыв соединения…
        raise _RequestError("connection", str(err) or type(err).__name__) from err


class _RequestError(Exception):
    def __init__(self, reason: str, message: str) -> None:
        super().__init__(message)
        self.reason = reason


class ProbeContext:
    """Контекст одного запуска: call(step, …) выполняет шаг и возвращает JSON
    (None для пустого ответа) или бросает ProbeFailure. X-Request-Id вида
    prober-<запуск>-<шаг> попадает в access-лог приложения: по нему в Victoria
    Logs находится серверная сторона упавшего шага."""

    def __init__(self, client: httpx.AsyncClient, base_url: str, timeout_ms: int, cleanup) -> None:
        self.client = client
        self.base_url = base_url
        self.timeout_ms = timeout_ms
        self.cleanup = cleanup
        self.run_id = str(uuid.uuid4())

    async def call(self, step: str, *, path: str, expect: int, method: str = "GET", body=None):
        request_id = f"prober-{self.run_id}-{step}"
        try:
            status, text = await send(
                self.client, method, f"{self.base_url}{path}", timeout_ms=self.timeout_ms,
                body=body, headers={"x-request-id": request_id},
            )
        except _RequestError as err:
            raise ProbeFailure(step, err.reason, str(err), request_id=request_id) from err
        if status != expect:
            reason = "server_error" if status >= 500 else "unexpected_status"
            raise ProbeFailure(step, reason, f"expected HTTP {expect}, got {status}", status, request_id)
        if text == "":
            return None
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            raise ProbeFailure(step, "invalid_body", "response body is not JSON", status, request_id) from None


async def list_projects(ctx: ProbeContext) -> None:
    """Чтение: главная страница интерфейса показывает список проектов."""
    page = await ctx.call("list_projects", path="/api/projects?limit=5", expect=200)
    check("list_projects", isinstance((page or {}).get("data"), list), "data is not an array")
    total = ((page or {}).get("meta") or {}).get("total")
    check("list_projects", isinstance(total, int) and not isinstance(total, bool), "meta.total is not an integer")


async def task_lifecycle(ctx: ProbeContext) -> None:
    """Запись: полный путь задачи — от создания проекта до каскадного удаления.
    Проверяется не только статус, но и что API вернул записанное (read-your-writes)."""
    project = await ctx.call(
        "create_project", method="POST", path="/api/projects", expect=201,
        body={"name": f"prober {ctx.run_id}", "description": "Synthetic probe, deleted automatically"},
    )
    project_id = ((project or {}).get("data") or {}).get("id")
    check("create_project", is_id(project_id), "data.id is not a project id")
    # Если проба оборвётся дальше, проект удалит следующий запуск (cleanup.py).
    ctx.cleanup.track(project_id)

    task = await ctx.call("create_task", method="POST", path="/api/tasks", expect=201,
                          body={"project_id": project_id, "title": "Probe task"})
    data = (task or {}).get("data") or {}
    check("create_task", is_id(data.get("id")), "data.id is not a task id")
    check("create_task", data.get("status") == "todo", f"new task status is {data.get('status')}")
    task_id = data["id"]

    for step, status in (("start_task", "in_progress"), ("finish_task", "done")):
        updated = await ctx.call(step, method="PUT", path=f"/api/tasks/{task_id}", expect=200, body={"status": status})
        got = ((updated or {}).get("data") or {}).get("status")
        check(step, got == status, f"task status is {got}")

    read = ((await ctx.call("get_task", path=f"/api/tasks/{task_id}", expect=200)) or {}).get("data") or {}
    check("get_task", read.get("status") == "done", f"task status is {read.get('status')}")
    check("get_task", read.get("project_id") == project_id, "task belongs to another project")

    await ctx.call("delete_project", method="DELETE", path=f"/api/projects/{project_id}", expect=204)
    ctx.cleanup.untrack(project_id)

    # Задачи удаляются вместе с проектом (ON DELETE CASCADE). 404 должен быть
    # ответом TaskFlow «задачи нет», а не чужим 404 (прокси, другой сервис).
    gone = await ctx.call("check_cascade", path=f"/api/tasks/{task_id}", expect=404)
    check("check_cascade", (gone or {}).get("error") == "Task not found", f"404 body is {json.dumps(gone)}")


@dataclass(frozen=True)
class Probe:
    name: str
    steps: tuple[str, ...]
    run: Callable[[ProbeContext], Awaitable[None]]
    # что сделать перед запуском — вне замера времени и вне результата
    prepare: Callable[[ProbeContext], Awaitable[None]] | None = None


async def _flush_cleanup(ctx: ProbeContext) -> None:
    await ctx.cleanup.flush()


PROBES = (
    Probe("list_projects", ("list_projects",), list_projects),
    Probe(
        "task_lifecycle",
        ("create_project", "create_task", "start_task", "finish_task", "get_task", "delete_project", "check_cascade"),
        task_lifecycle,
        prepare=_flush_cleanup,
    ),
)
