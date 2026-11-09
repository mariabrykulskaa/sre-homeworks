"""Отдельный HTTP-сервер для /metrics на своём порту (METRICS_PORT).

Почему не маршрут в основном приложении:
  * порт не публикуется в Service, поэтому метрики не видны снаружи кластера —
    авторизация не нужна, но и выставлять их наружу незачем;
  * скрейпы не проходят через rate limit и не пишут access-лог (иначе каждые
    15 секунд на каждой реплике в логах появлялась бы строка о скрейпе);
  * сервер работает в своём потоке: даже если цикл событий приложения занят,
    скрейп отвечает, а при остановке пода метрики отдаются до последнего.
"""

import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import CollectorRegistry
from prometheus_client.openmetrics.exposition import CONTENT_TYPE_LATEST, generate_latest


def create_metrics_server(registry: CollectorRegistry, logger, host: str, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def _plain(self, status: int, text: str, extra: dict | None = None) -> None:
            body = text.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("X-Content-Type-Options", "nosniff")
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _metrics(self) -> None:
            if self.path.split("?", 1)[0] != "/metrics":
                self._plain(404, "Not found\n")
                return
            try:
                body = generate_latest(registry)
            except Exception as err:  # noqa: BLE001
                # Ошибка сбора — 500, чтобы скрейп считался неудачным (up = 0),
                # а не молча сохранил неполный набор рядов.
                logger.error("metrics collection failed", error=err)
                self._plain(500, "Metrics collection failed\n")
                return
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        do_GET = _metrics
        do_HEAD = _metrics

        def _not_allowed(self) -> None:
            self._plain(405, "Method not allowed\n", {"Allow": "GET, HEAD"})

        do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _not_allowed

        def log_message(self, format, *args):  # noqa: A002 — сигнатура BaseHTTPRequestHandler
            pass  # скрейпы не пишут в лог

    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server


def start_in_thread(server: ThreadingHTTPServer) -> threading.Thread:
    thread = threading.Thread(target=server.serve_forever, name="metrics-server", daemon=True)
    thread.start()
    return thread
