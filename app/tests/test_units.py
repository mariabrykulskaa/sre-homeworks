"""Юнит-тесты без БД: сбои, конфигурация, логгер, сервер метрик."""

import asyncio
import io
import json
import urllib.error
import urllib.request

import pytest

from taskflow import metrics
from taskflow.config import load_config
from taskflow.faults import (
    FaultInjector,
    InjectedFaultError,
    allocate_memory_ballast,
    parse_error_rate,
    parse_latency_ms,
    parse_memory_mb,
)
from taskflow.logger import Logger
from taskflow.metrics_server import create_metrics_server, start_in_thread
from taskflow.middleware import level_for_status, resolve_request_id


# --- faults -------------------------------------------------------------------
def test_fault_parsers_accept_decimals_and_empty():
    assert parse_error_rate(None) == 0
    assert parse_error_rate("") == 0
    assert parse_error_rate(" 0.25 ") == 0.25
    assert parse_latency_ms("300") == 300
    assert parse_memory_mb("200") == 200


@pytest.mark.parametrize("raw", ["0x10", "0b1", "1.5", "-0.1", "abc", "0.1abc"])
def test_fault_error_rate_rejects_non_decimal_and_out_of_range(raw):
    with pytest.raises(ValueError):
        parse_error_rate(raw)


@pytest.mark.parametrize("raw", ["1.5", "-1", "30001"])
def test_fault_latency_rejects_bad_values(raw):
    with pytest.raises(ValueError):
        parse_latency_ms(raw)


def test_fault_injector_errors_and_delay():
    asyncio.run(FaultInjector(error_rate=0.5, rng=lambda: 0.9)())  # 0.9 ≥ 0.5 — без ошибки
    with pytest.raises(InjectedFaultError):
        asyncio.run(FaultInjector(error_rate=0.5, rng=lambda: 0.1)())


def test_memory_ballast_size():
    assert len(allocate_memory_ballast(2)) == 2 * 1024 * 1024


# --- config -------------------------------------------------------------------
def test_config_requires_database_url_and_distinct_ports():
    with pytest.raises(ValueError, match="DATABASE_URL"):
        load_config({})
    with pytest.raises(ValueError, match="METRICS_PORT must differ"):
        load_config({"DATABASE_URL": "x", "PORT": "9464"})
    with pytest.raises(ValueError, match="FAULT_ERROR_RATE"):
        load_config({"DATABASE_URL": "x", "FAULT_ERROR_RATE": "2"})
    config = load_config({"DATABASE_URL": "x"})
    assert (config.port, config.metrics_port, config.host, config.rate_limit) == (3000, 9464, "127.0.0.1", 600)


# --- logger -------------------------------------------------------------------
def test_logger_writes_one_json_line_with_schema_fields():
    out = io.StringIO()
    log = Logger(stream=out, service="taskflow", env="test", now=lambda: "T").child(request_id="r1")
    log.info("request", status=201, skipped=None, level="hacked")
    record = json.loads(out.getvalue())
    assert record == {
        "timestamp": "T", "level": "info", "message": "request", "service.name": "taskflow",
        "service.version": log.version, "deployment.environment": "test", "request_id": "r1", "status": 201,
    }


def test_logger_flattens_errors_and_respects_level():
    out = io.StringIO()
    log = Logger(stream=out, level="warn")
    log.info("dropped")
    try:
        raise RuntimeError("boom")
    except RuntimeError as err:
        log.error("failed", error=err)
    record = json.loads(out.getvalue())
    assert record["message"] == "failed"
    assert record["error.message"] == "boom"
    assert record["error.type"] == "RuntimeError"
    assert "Traceback" in record["error.stack"]


def test_logger_rejects_unknown_level():
    with pytest.raises(ValueError):
        Logger(level="verbose")


def test_request_id_and_level_helpers():
    assert resolve_request_id("abc-1.2_3") == "abc-1.2_3"
    assert resolve_request_id("bad id!") != "bad id!"
    assert [level_for_status(s) for s in (200, 404, 500)] == ["info", "warn", "error"]


# --- metrics server -----------------------------------------------------------
@pytest.fixture
def metrics_url():
    server = create_metrics_server(metrics.registry, Logger(stream=io.StringIO()), "127.0.0.1", 0)
    start_in_thread(server)
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


def test_metrics_endpoint_serves_openmetrics(metrics_url):
    with urllib.request.urlopen(f"{metrics_url}/metrics") as res:
        body = res.read().decode()
        assert res.headers["Content-Type"].startswith("application/openmetrics-text")
    assert body.rstrip().endswith("# EOF")
    assert 'taskflow_task_status_transitions_total{from="todo",to="in_progress"}' in body
    assert "python_gc_collections_total" in body
    # служебные ряды *_created отключены (disable_created_metrics)
    assert "http_request_duration_seconds_created" not in body
    assert "taskflow_projects_created_created" not in body


@pytest.mark.parametrize(("path", "method", "status"), [("/other", "GET", 404), ("/metrics", "POST", 405)])
def test_metrics_endpoint_rejects_other_paths_and_methods(metrics_url, path, method, status):
    with pytest.raises(urllib.error.HTTPError) as info:
        urllib.request.urlopen(urllib.request.Request(f"{metrics_url}{path}", method=method, data=b"" if method == "POST" else None))
    assert info.value.code == status
