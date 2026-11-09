"""Уборка за пробой: проект, созданный пробой, оборвавшейся до шага
delete_project, удаляется перед следующим запуском. Иначе каждая неуспешная
проба (а во время сбоя их много) оставляла бы в базе мусорный проект.

Очередь — в памяти процесса и ограничена: при перезапуске пробера или очень
долгом сбое часть проектов останется (их имена начинаются с «prober »).
"""

from .probes import _RequestError, send

DEFAULT_CLEANUP_LIMIT = 100


class Cleanup:
    def __init__(self, client, base_url: str, timeout_ms: int, logger, limit: int = DEFAULT_CLEANUP_LIMIT) -> None:
        self.client = client
        self.base_url = base_url
        self.timeout_ms = timeout_ms
        self.logger = logger
        self.limit = limit
        self._pending: dict[str, None] = {}  # упорядоченное множество

    def track(self, project_id: str) -> None:
        if len(self._pending) >= self.limit:
            oldest = next(iter(self._pending))
            del self._pending[oldest]
            self.logger.warn("cleanup queue full, probe project abandoned", project_id=oldest, limit=self.limit)
        self._pending[project_id] = None

    def untrack(self, project_id: str) -> None:
        self._pending.pop(project_id, None)

    def pending_ids(self) -> list[str]:
        return list(self._pending)

    async def flush(self) -> None:
        """204 — удалили, 404 — его уже нет. На первой неудаче уборка прерывается
        до следующего запуска: сбой продолжается, и остальные попытки (каждая —
        до таймаута) только задержали бы пробу."""
        for project_id in list(self._pending):
            try:
                status, _ = await send(
                    self.client, "DELETE", f"{self.base_url}/api/projects/{project_id}",
                    timeout_ms=self.timeout_ms, headers={"x-request-id": f"prober-cleanup-{project_id}"},
                )
            except _RequestError as err:
                self.logger.debug("leftover probe project not deleted yet", project_id=project_id, error=err)
                return
            if status not in (204, 404):
                self.logger.debug("leftover probe project not deleted yet", project_id=project_id, status=status)
                return
            self.untrack(project_id)
            self.logger.info("leftover probe project deleted", project_id=project_id, status=status)
