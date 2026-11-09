import io
import json
import os

import psycopg
import pytest
from fastapi.testclient import TestClient

from taskflow.app import create_app
from taskflow.config import load_config
from taskflow.logger import Logger
from taskflow.migrate import migrate

# Интеграционные тесты ходят в отдельную БД с именем на _test — чтобы случайно
# не стереть рабочие данные.
DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://taskflow:taskflow@localhost:5432/taskflow_test")


@pytest.fixture(scope="session")
def database_url():
    name = DATABASE_URL.rsplit("/", 1)[-1].split("?", 1)[0]
    if not name.endswith("_test"):
        pytest.exit(f'Integration tests need a database whose name ends with "_test", got "{name}"')
    admin_url = DATABASE_URL.rsplit("/", 1)[0] + "/postgres"
    with psycopg.connect(admin_url, autocommit=True) as conn:
        if not conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (name,)).fetchone():
            conn.execute(f'CREATE DATABASE "{name}"')
    with psycopg.connect(DATABASE_URL, autocommit=True) as conn:
        migrate(conn, Logger(stream=io.StringIO()))
        conn.execute("TRUNCATE projects, tasks RESTART IDENTITY CASCADE")
    return DATABASE_URL


class LogCapture(io.StringIO):
    def records(self) -> list[dict]:
        return [json.loads(line) for line in self.getvalue().splitlines() if line]


@pytest.fixture
def make_client(database_url):
    clients = []

    def factory(**env):
        config = load_config({"DATABASE_URL": database_url, "RATE_LIMIT_PER_MINUTE": "100000", **env})
        logs = LogCapture()
        app = create_app(config, Logger(stream=logs, level="debug"))
        client = TestClient(app)
        client.__enter__()
        client.logs = logs
        clients.append(client)
        return client

    yield factory
    for client in clients:
        client.__exit__(None, None, None)


@pytest.fixture
def client(make_client):
    return make_client()
