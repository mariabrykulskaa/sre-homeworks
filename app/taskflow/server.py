"""Точка входа: python -m taskflow.server

VI. Процессы — одно stateless-приложение; VII. Привязка портов — сервис сам
слушает PORT; IX. Утилизируемость — быстрый старт и корректное завершение:
по SIGTERM uvicorn перестаёт принимать соединения, дожидается активных запросов
(не дольше 10 секунд), затем закрывается пул соединений с БД.
"""

import asyncio
import sys
import threading

import uvicorn

from .app import create_app
from .config import load_config
from .faults import allocate_memory_ballast
from .logger import logger, route_stdlib_logging
from .metrics import fault_delay_seconds, fault_error_ratio, fault_memory_bytes, registry
from .metrics_server import create_metrics_server, start_in_thread

SHUTDOWN_TIMEOUT_SECONDS = 10


def install_process_error_handlers() -> None:
    """Необработанная ошибка — одной JSON-записью в лог, а не текстовым трейсбеком."""

    def excepthook(exc_type, exc, tb):
        logger.error("uncaught exception", error=exc)
        sys.exit(1)

    def thread_excepthook(args):
        logger.error("uncaught exception", thread=args.thread.name if args.thread else None, error=args.exc_value)

    sys.excepthook = excepthook
    threading.excepthook = thread_excepthook


def main() -> None:
    install_process_error_handlers()
    route_stdlib_logging(logger)

    try:
        config = load_config()
    except ValueError as err:
        logger.error("invalid configuration", error=err)
        sys.exit(1)

    # Внесение сбоев включается только намеренно — пусть это будет видно и в
    # логе, и в метриках с первой секунды работы реплики.
    fault_error_ratio.set(config.fault_error_rate)
    fault_delay_seconds.set(config.fault_latency_ms / 1000)
    ballast = allocate_memory_ballast(config.fault_memory_mb) if config.fault_memory_mb else b""
    fault_memory_bytes.set(len(ballast))
    if config.fault_error_rate or config.fault_latency_ms or config.fault_memory_mb:
        logger.warn(
            "fault injection enabled",
            fault_error_rate=config.fault_error_rate,
            fault_latency_ms=config.fault_latency_ms,
            fault_memory_mb=config.fault_memory_mb,
        )

    # /metrics — на отдельном порту, только для системы мониторинга.
    # Сервер метрик работает в своём потоке до самого выхода процесса:
    # пока основной сервер дорабатывает запросы, скрейпы продолжаются.
    try:
        metrics_server = create_metrics_server(registry, logger, config.host, config.metrics_port)
    except OSError as err:
        logger.error("metrics listen failed", host=config.host, port=config.metrics_port, error=err)
        sys.exit(1)
    start_in_thread(metrics_server)
    logger.info("metrics server started", host=config.host, port=config.metrics_port)

    app = create_app(config, logger)
    server = uvicorn.Server(uvicorn.Config(
        app,
        host=config.host,
        port=config.port,
        log_config=None,  # логи uvicorn — через наш JSON-логгер (route_stdlib_logging)
        access_log=False,  # access-лог пишет middleware: одна строка на запрос
        timeout_graceful_shutdown=SHUTDOWN_TIMEOUT_SECONDS,
        server_header=False,
    ))
    logger.info("server started", host=config.host, port=config.port)
    asyncio.run(server.serve())
    logger.info("server stopped")
    _ = ballast  # балласт живёт до конца процесса


if __name__ == "__main__":
    main()
