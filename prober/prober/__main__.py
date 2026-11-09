"""Точка входа пробера (python -m prober): конфигурация из окружения, /metrics
для vmagent, циклы проб и корректное завершение по SIGTERM."""

import asyncio
import os
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client.openmetrics.exposition import CONTENT_TYPE_LATEST, generate_latest

from .cleanup import Cleanup
from .config import load_config
from .logger import Logger
from .metrics import ProberMetrics
from .probes import PROBES, ProbeContext, new_client
from .runner import probe_loops, run_probe

SHUTDOWN_TIMEOUT_SECONDS = 20


def start_metrics_server(registry, host: str, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def _serve(self):
            if self.path.split("?", 1)[0] != "/metrics":
                self.send_response(404)
                self.end_headers()
                return
            body = generate_latest(registry)
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        do_GET = do_HEAD = _serve

        def log_message(self, format, *args):  # noqa: A002
            pass

    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, name="metrics-server", daemon=True).start()
    return server


async def main() -> None:
    logger = Logger()
    try:
        config = load_config(dict(os.environ))
    except ValueError as err:
        logger.error("invalid configuration", error=err)
        sys.exit(1)

    metrics = ProberMetrics(PROBES)
    try:
        start_metrics_server(metrics.registry, config.host, config.metrics_port)
    except OSError as err:
        logger.error("metrics listen failed", host=config.host, port=config.metrics_port, error=err)
        sys.exit(1)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda s=sig: (logger.info("shutting down", signal=s.name), stop.set()))

    async with new_client() as client:
        cleanup = Cleanup(client, config.target_url, config.request_timeout_ms, logger)

        async def run(probe):
            ctx = ProbeContext(client, config.target_url, config.request_timeout_ms, cleanup)
            return await run_probe(probe, ctx, metrics, logger)

        logger.info(
            "prober started", target_url=config.target_url, probes=",".join(p.name for p in PROBES),
            interval_seconds=config.interval_seconds, request_timeout_ms=config.request_timeout_ms,
            metrics_port=config.metrics_port,
        )
        await probe_loops(PROBES, config.interval_seconds, run, stop)
        # Текущие запуски доведены до конца; убираем то, что оставили оборванные пробы.
        await asyncio.wait_for(cleanup.flush(), SHUTDOWN_TIMEOUT_SECONDS)
        if cleanup.pending_ids():
            logger.warn("probe projects left in the database", project_ids=",".join(cleanup.pending_ids()))


if __name__ == "__main__":
    asyncio.run(main())
