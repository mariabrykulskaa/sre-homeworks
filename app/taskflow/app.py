"""Сборка приложения: middleware, обработчики ошибок, маршруты, статика фронтенда."""

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from .config import Config
from .db import Database
from .errors import HttpError
from .faults import FaultInjector
from .logger import Logger
from .metrics import http_request_duration
from .middleware import RateLimitMiddleware, RequestContextMiddleware
from .routes import projects, tasks

PUBLIC_DIR = Path(__file__).resolve().parent.parent / "public"


def create_app(config: Config, logger: Logger, db: Database | None = None) -> FastAPI:
    database = db or Database(
        config.database_url,
        FaultInjector(error_rate=config.fault_error_rate, latency_ms=config.fault_latency_ms),
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await database.open()
        yield
        # IX. Корректное завершение: по SIGTERM uvicorn перестал принимать
        # соединения и дождался активных запросов; закрываем соединения с БД.
        logger.info("shutting down")
        await database.close()

    # /docs — автодокументация API; схема генерируется по маршрутам.
    app = FastAPI(title="TaskFlow", version=logger.version, lifespan=lifespan)
    app.state.db = database
    app.state.logger = logger

    # Последний добавленный middleware — внешний: сначала контекст запроса
    # (лог, метрики, request_id), внутри него — лимит запросов.
    app.add_middleware(RateLimitMiddleware, limit=config.rate_limit)
    app.add_middleware(
        RequestContextMiddleware, logger=logger, histogram=http_request_duration, instance=config.instance
    )

    @app.exception_handler(HttpError)
    async def http_error(request: Request, exc: HttpError):
        return JSONResponse({"error": exc.message}, status_code=exc.status)

    @app.exception_handler(StarletteHTTPException)
    async def starlette_error(request: Request, exc: StarletteHTTPException):
        message = {404: "Not found", 405: "Method not allowed"}.get(exc.status_code, exc.detail)
        return JSONResponse({"error": message}, status_code=exc.status_code, headers=exc.headers)

    # Liveness: процесс жив. В БД не ходит, чтобы оркестратор не перезапускал
    # здоровые реплики при кратком сбое базы.
    @app.get("/api/health")
    async def health():
        return {"status": "ok"}

    # Readiness: готовность обслуживать запросы, включая соединение с БД.
    @app.get("/api/ready")
    async def ready(request: Request):
        try:
            await database.ping()
        except Exception as err:  # noqa: BLE001
            request.state.log.error("readiness check failed", error=err)
            return JSONResponse({"status": "degraded"}, status_code=503)
        return {"status": "ready"}

    # Какая версия и какая реплика ответили. То же есть в заголовках
    # X-App-Version / X-Served-By любого ответа, в поле service.version каждой
    # строки лога и в метрике taskflow_build_info.
    @app.get("/api/version")
    async def version():
        return {"service": logger.service, "version": logger.version, "instance": config.instance}

    app.include_router(projects.router)
    app.include_router(tasks.router)

    # Всё, что не /api, — файлы фронтенда (index.html, app.js, styles.css).
    app.mount("/", StaticFiles(directory=PUBLIC_DIR, html=True), name="static")
    return app
