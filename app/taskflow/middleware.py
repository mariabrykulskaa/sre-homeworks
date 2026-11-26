"""Промежуточные обработчики (ASGI middleware), через которые проходит КАЖДЫЙ запрос.

RequestContextMiddleware — внешний слой:
  * request_id: из входящего X-Request-Id (если похож на идентификатор), иначе
    новый UUID; возвращается клиенту и попадает в каждую строку лога запроса —
    по нему в Victoria Logs собирается вся история одного вызова;
  * защитные заголовки ответа (CSP, X-Frame-Options и др.);
  * X-App-Version и X-Served-By — версия и реплика, ответившие на запрос: по ним
    видно, куда шлюз направил запрос при выкатке (ДЗ №8);
  * access-лог: одна JSON-строка на запрос (XI фактор);
  * HTTP-метрика http_request_duration_seconds{method, route, status_code};
  * непредвиденная ошибка → лог «unhandled error» и ответ 500.
RateLimitMiddleware — лимит запросов к /api с одного IP в минуту.
"""

import json
import re
import time
import uuid
from collections import defaultdict

from .logger import Logger

_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
_PATH_PARAM = re.compile(r"\{[^}]+\}")
QUERY_MAX_LENGTH = 512

# Значения route для запросов, не дошедших до обработчика маршрута:
#   unmatched — под /api: 404, превышение лимита (отклонены до маршрутизации);
#   static    — всё остальное: файлы интерфейса из public/ и их 404.
UNMATCHED_ROUTE = "unmatched"
STATIC_ROUTE = "static"

CSP = "; ".join([
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "font-src 'self'",
    "img-src 'self' data:",
    "connect-src 'self'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    "base-uri 'self'",
])
SECURITY_HEADERS = [
    (b"content-security-policy", CSP.encode()),
    (b"x-content-type-options", b"nosniff"),
    (b"x-frame-options", b"DENY"),
    (b"referrer-policy", b"strict-origin-when-cross-origin"),
]


def resolve_request_id(header: str | None) -> str:
    return header if header and _REQUEST_ID.match(header) else str(uuid.uuid4())


def level_for_status(status: int) -> str:
    """5xx — наша ошибка (error), 4xx — ошибка клиента (warn), остальное — info."""
    if status >= 500:
        return "error"
    if status >= 400:
        return "warn"
    return "info"


def route_of(scope: dict) -> str:
    """Шаблон маршрута для метки route: /api/tasks/{task_id} → /api/tasks/:id."""
    route = scope.get("route")
    path_template = getattr(route, "path", None)
    if path_template and path_template.startswith("/api"):
        return _PATH_PARAM.sub(":id", path_template)
    path = scope.get("path", "")
    return UNMATCHED_ROUTE if path == "/api" or path.startswith("/api/") else STATIC_ROUTE


def _header(scope: dict, name: bytes) -> str | None:
    for key, value in scope.get("headers", []):
        if key == name:
            return value.decode("latin-1")
    return None


class RequestContextMiddleware:
    def __init__(self, app, logger: Logger, histogram, instance: str = "") -> None:
        self.app = app
        self.logger = logger
        self.histogram = histogram
        self.identity_headers = [(b"x-app-version", logger.version.encode())]
        if instance:
            self.identity_headers.append((b"x-served-by", instance.encode()))

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request_id = resolve_request_id(_header(scope, b"x-request-id"))
        log = self.logger.child(request_id=request_id)
        # request.state.log в обработчиках — логгер с request_id.
        scope.setdefault("state", {})["log"] = log
        started = time.perf_counter()
        outcome = {"status": None, "finished": False, "error": None}

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                outcome["status"] = message["status"]
                headers = list(message.get("headers", []))
                headers.extend(SECURITY_HEADERS)
                headers.extend(self.identity_headers)
                headers.append((b"x-request-id", request_id.encode()))
                message = {**message, "headers": headers}
            elif message["type"] == "http.response.body" and not message.get("more_body", False):
                outcome["finished"] = True
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        except Exception as err:  # noqa: BLE001 — последняя линия обороны
            path = scope.get("path", "")
            if outcome["status"] is None:
                log.error("unhandled error", method=scope["method"], path=path, error=err)
                body = json.dumps({"error": "Internal server error"}).encode()
                await send_wrapper({
                    "type": "http.response.start",
                    "status": 500,
                    "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
                })
                await send_wrapper({"type": "http.response.body", "body": body})
            else:
                # Ответ уже начал отправляться — менять статус поздно; обрываем.
                log.error("error after headers sent", method=scope["method"], path=path, error=err)
                outcome["error"] = err
        finally:
            self._record(scope, log, started, outcome)

    def _record(self, scope: dict, log: Logger, started: float, outcome: dict) -> None:
        seconds = time.perf_counter() - started
        # Чем закончился запрос: ответ дописан — его статус; оборван сервером —
        # 500; не дописан без нашей ошибки — 499 (клиент ушёл раньше).
        if outcome["error"] is not None:
            status, aborted = 500, True
        elif outcome["finished"]:
            status, aborted = outcome["status"], None
        else:
            status, aborted = 499, True

        method = scope["method"]
        self.histogram.labels(method=method, route=route_of(scope), status_code=str(status)).observe(seconds)

        query = scope.get("query_string", b"").decode("latin-1")
        client = scope.get("client")
        getattr(log, level_for_status(status))(
            "request",
            method=method,
            # Host запроса: за шлюзом одна реплика может получать запросы на
            # разные имена (taskflow.local, preview.taskflow.local в blue/green).
            host=_header(scope, b"host"),
            path=scope.get("path", ""),
            query=query[:QUERY_MAX_LENGTH] or None,
            status=status,
            aborted=aborted,
            duration_ms=round(seconds * 1000, 1),
            client_ip=client[0] if client else None,
            error=outcome["error"],
        )


class RateLimitMiddleware:
    """Фиксированное окно в минуту на IP-адрес клиента, отдельно для проб.

    Пробы оркестратора (/api/health, /api/ready) не тратят бюджет
    пользовательского трафика, но и у них свой потолок: /api/ready ходит в БД.
    Счётчики в памяти реплики — для учебного проекта этого достаточно
    (у каждой реплики свой лимит).
    """

    WINDOW_SECONDS = 60
    PROBE_LIMIT = 120

    def __init__(self, app, limit: int) -> None:
        self.app = app
        self.limit = limit
        self._window_start = 0.0
        self._counts: dict = defaultdict(int)

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not (scope["path"] == "/api" or scope["path"].startswith("/api/")):
            await self.app(scope, receive, send)
            return

        now = time.monotonic()
        if now - self._window_start >= self.WINDOW_SECONDS:
            self._window_start = now
            self._counts.clear()

        path = scope["path"].rstrip("/")
        is_probe = scope["method"] == "GET" and path in ("/api/health", "/api/ready")
        limit = self.PROBE_LIMIT if is_probe else self.limit
        client = scope.get("client")
        key = (client[0] if client else "unknown", is_probe)
        self._counts[key] += 1
        remaining = max(0, limit - self._counts[key])
        reset = max(0, int(self.WINDOW_SECONDS - (now - self._window_start)))
        rate_headers = [
            (b"ratelimit-policy", f"{limit};w={self.WINDOW_SECONDS}".encode()),
            (b"ratelimit", f"limit={limit}, remaining={remaining}, reset={reset}".encode()),
        ]

        if self._counts[key] > limit:
            body = json.dumps({"error": "Too many requests"}).encode()
            await send({
                "type": "http.response.start",
                "status": 429,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode()),
                    (b"retry-after", str(reset).encode()),
                    *rate_headers,
                ],
            })
            await send({"type": "http.response.body", "body": body})
            return

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                message = {**message, "headers": [*message.get("headers", []), *rate_headers]}
            await send(message)

        await self.app(scope, receive, send_with_headers)
