import asyncio
import io
import json

import httpx
import pytest

from prober.cleanup import Cleanup
from prober.config import load_config
from prober.logger import Logger
from prober.metrics import ProberMetrics
from prober.probes import PROBES, ProbeContext, new_client
from prober.runner import run_probe

BASE = "http://taskflow.test"


class FakeTaskFlow:
    """Минимальный TaskFlow в памяти: ровно то API, которым пользуются пробы."""

    def __init__(self):
        self.projects, self.tasks, self.next_id = {}, {}, 1
        self.fail = None  # функция(request) -> httpx.Response | Exception | None

    def _id(self):
        self.next_id += 1
        return str(self.next_id)

    async def __call__(self, request: httpx.Request):
        if self.fail:
            injected = self.fail(request)
            if isinstance(injected, Exception):
                raise injected
            if injected is not None:
                return injected
        path, method = request.url.path, request.method
        body = json.loads(request.content) if request.content else None
        if path == "/api/projects" and method == "GET":
            return httpx.Response(200, json={"data": list(self.projects.values()), "meta": {"total": len(self.projects)}})
        if path == "/api/projects" and method == "POST":
            pid = self._id()
            self.projects[pid] = {"id": pid, **body}
            return httpx.Response(201, json={"data": self.projects[pid]})
        if path.startswith("/api/projects/") and method == "DELETE":
            pid = path.rsplit("/", 1)[1]
            if self.projects.pop(pid, None) is None:
                return httpx.Response(404, json={"error": "Project not found"})
            self.tasks = {k: t for k, t in self.tasks.items() if t["project_id"] != pid}
            return httpx.Response(204)
        if path == "/api/tasks" and method == "POST":
            tid = self._id()
            self.tasks[tid] = {"id": tid, "project_id": body["project_id"], "title": body["title"], "status": "todo"}
            return httpx.Response(201, json={"data": self.tasks[tid]})
        if path.startswith("/api/tasks/"):
            task = self.tasks.get(path.rsplit("/", 1)[1])
            if task is None:
                return httpx.Response(404, json={"error": "Task not found"})
            if method == "PUT":
                task.update(body)
            return httpx.Response(200, json={"data": task})
        return httpx.Response(404, json={"error": "Not found"})


def run(fake, probe_name, timeout_ms=200):
    probe = next(p for p in PROBES if p.name == probe_name)
    metrics = ProberMetrics(PROBES)
    logs = io.StringIO()

    async def go():
        async with new_client(httpx.MockTransport(fake)) as client:
            cleanup = Cleanup(client, BASE, timeout_ms, Logger(stream=logs))
            result = await run_probe(probe, ProbeContext(client, BASE, timeout_ms, cleanup), metrics, Logger(stream=logs))
            return result, cleanup

    result, cleanup = asyncio.run(go())
    return result, metrics, cleanup


def value(metrics, name, **labels):
    return metrics.registry.get_sample_value(name, labels)


def test_both_probes_succeed_and_clean_up():
    fake = FakeTaskFlow()
    for name in ("list_projects", "task_lifecycle"):
        result, metrics, cleanup = run(fake, name)
        assert result == {"ok": True}
        assert value(metrics, "prober_probe_runs_total", probe=name, result="success") == 1
        assert value(metrics, "prober_probe_success", probe=name) == 1
        assert cleanup.pending_ids() == []
    assert fake.projects == {} and fake.tasks == {}


def test_server_error_is_counted_with_step_and_reason():
    fake = FakeTaskFlow()
    fake.fail = lambda r: httpx.Response(500, json={"error": "Internal server error"}) if r.method == "PUT" else None
    result, metrics, cleanup = run(fake, "task_lifecycle")
    assert result == {"ok": False, "step": "start_task", "reason": "server_error"}
    assert value(metrics, "prober_probe_runs_total", probe="task_lifecycle", result="failure") == 1
    assert value(metrics, "prober_probe_failures_total", probe="task_lifecycle", step="start_task", reason="server_error") == 1
    assert len(cleanup.pending_ids()) == 1  # проект удалит следующий запуск


def test_connection_error_and_timeout():
    fake = FakeTaskFlow()
    fake.fail = lambda r: httpx.ConnectError("connection refused")
    assert run(fake, "list_projects")[0]["reason"] == "connection"

    async def slow(request):
        await asyncio.sleep(1)
        return httpx.Response(200, json={})

    assert run(slow, "list_projects", timeout_ms=100)[0]["reason"] == "timeout"


def test_invalid_body_and_foreign_404():
    fake = FakeTaskFlow()
    fake.fail = lambda r: httpx.Response(200, text="<html>") if r.method == "GET" else None
    assert run(fake, "list_projects")[0]["reason"] == "invalid_body"
    fake.fail = lambda r: httpx.Response(404, json={"error": "nginx"}) if r.url.path.startswith("/api/tasks/") and r.method == "GET" else None
    result = run(fake, "task_lifecycle")[0]
    assert (result["step"], result["reason"]) == ("get_task", "unexpected_status")


def test_internal_error_is_not_a_failure():
    def broken(request):
        raise RuntimeError("bug in prober")

    result, metrics, _ = run(broken, "list_projects")
    assert result == {"ok": False, "internal": True}
    assert value(metrics, "prober_internal_errors_total", probe="list_projects") == 1
    assert value(metrics, "prober_probe_runs_total", probe="list_projects", result="failure") == 0


def test_series_are_initialised_with_zero():
    metrics = ProberMetrics(PROBES)
    assert value(metrics, "prober_probe_failures_total", probe="task_lifecycle", step="check_cascade", reason="timeout") == 0


def test_config():
    config = load_config({"TARGET_URL": "http://taskflow/"})
    assert (config.target_url, config.interval_seconds, config.request_timeout_ms) == ("http://taskflow", 5, 2000)
    for bad in ({}, {"TARGET_URL": "ftp://x"}, {"TARGET_URL": "http://u:p@x"},
                {"TARGET_URL": "http://x", "REQUEST_TIMEOUT_MS": "9000"}):
        with pytest.raises(ValueError):
            load_config(bad)
