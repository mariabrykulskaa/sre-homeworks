"""III. Конфигурация: всё, что меняется между окружениями, — из переменных окружения.

.env подхватывается только как удобство для локальной разработки (файл в
.gitignore и в образ не попадает). Неверное значение — ошибка на старте
(fail fast), а не посреди работы.
"""

import os
from dataclasses import dataclass

from dotenv import load_dotenv

from .faults import parse_error_rate, parse_latency_ms, parse_memory_mb


@dataclass(frozen=True)
class Config:
    port: int
    host: str
    database_url: str
    env: str
    rate_limit: int
    metrics_port: int
    fault_error_rate: float
    fault_latency_ms: int
    fault_memory_mb: int


def _require(env: dict, name: str) -> str:
    value = env.get(name)
    if not value:
        raise ValueError(f"Required environment variable {name} is not set")
    return value


def _port(env: dict, name: str, default: str) -> int:
    raw = env.get(name, default)
    if not raw.isdigit() or not 0 < int(raw) <= 65535:
        raise ValueError(f'{name} must be a valid port number, got "{raw}"')
    return int(raw)


def load_config(env: dict | None = None) -> Config:
    """Чистая функция: в тестах подаём свой словарь вместо os.environ."""
    if env is None:
        load_dotenv()
        env = dict(os.environ)

    port = _port(env, "PORT", "3000")
    metrics_port = _port(env, "METRICS_PORT", "9464")
    if metrics_port == port:
        raise ValueError(f"METRICS_PORT must differ from PORT (both are {port})")

    rate_limit_raw = env.get("RATE_LIMIT_PER_MINUTE", "600")
    if not rate_limit_raw.isdigit() or int(rate_limit_raw) <= 0:
        raise ValueError(f'RATE_LIMIT_PER_MINUTE must be a positive integer, got "{rate_limit_raw}"')

    return Config(
        port=port,
        # По умолчанию слушаем только loopback: API без аутентификации не должен
        # быть виден всей локальной сети. В контейнере HOST=0.0.0.0 (см. Dockerfile).
        host=env.get("HOST", "127.0.0.1"),
        database_url=_require(env, "DATABASE_URL"),
        env=env.get("APP_ENV", "development"),
        rate_limit=int(rate_limit_raw),
        # Отдельный порт для /metrics: в Service он не публикуется, поэтому
        # метрики доступны только изнутри кластера.
        metrics_port=metrics_port,
        fault_error_rate=parse_error_rate(env.get("FAULT_ERROR_RATE")),
        fault_latency_ms=parse_latency_ms(env.get("FAULT_LATENCY_MS")),
        fault_memory_mb=parse_memory_mb(env.get("FAULT_MEMORY_MB")),
    )
