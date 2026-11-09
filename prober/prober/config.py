"""Конфигурация пробера — только из переменных окружения (III фактор).

  TARGET_URL               адрес TaskFlow, как его видит клиент (обязательно):
                           в кластере — Service, http://taskflow.taskflow.svc.cluster.local
  PROBE_INTERVAL_SECONDS   как часто запускать каждую пробу (по умолчанию 5)
  REQUEST_TIMEOUT_MS       таймаут одного HTTP-запроса пробы (по умолчанию 2000)
  METRICS_PORT             порт /metrics (по умолчанию 9464)
  HOST                     адрес прослушивания /metrics (по умолчанию 127.0.0.1;
                           в контейнере — 0.0.0.0)
  LOG_LEVEL                debug | info | warn | error (по умолчанию info)
"""

from dataclasses import dataclass
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Config:
    target_url: str
    interval_seconds: int
    request_timeout_ms: int
    metrics_port: int
    host: str


def _integer(env: dict, name: str, default: int, minimum: int, maximum: int) -> int:
    raw = str(env.get(name, "")).strip()
    if raw == "":
        return default
    if not raw.isdigit() or not minimum <= int(raw) <= maximum:
        raise ValueError(f'{name} must be an integer from {minimum} to {maximum}, got "{env.get(name)}"')
    return int(raw)


def _target_url(raw: str | None) -> str:
    value = (raw or "").strip()
    if not value:
        raise ValueError("Required environment variable TARGET_URL is not set")
    parts = urlsplit(value)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        raise ValueError(f'TARGET_URL must be an absolute http(s) URL, got "{value}"')
    if parts.username or parts.password or parts.query or parts.fragment:
        raise ValueError("TARGET_URL must not contain credentials, a query string or a fragment")
    # Пути API добавляются к адресу: «…/» и «…» — одно и то же.
    return value.rstrip("/")


def load_config(env: dict) -> Config:
    config = Config(
        target_url=_target_url(env.get("TARGET_URL")),
        interval_seconds=_integer(env, "PROBE_INTERVAL_SECONDS", 5, 1, 300),
        request_timeout_ms=_integer(env, "REQUEST_TIMEOUT_MS", 2000, 100, 60_000),
        metrics_port=_integer(env, "METRICS_PORT", 9464, 1, 65_535),
        host=str(env.get("HOST", "")).strip() or "127.0.0.1",
    )
    # Если таймаут длиннее интервала, во время сбоя проба запускалась бы реже
    # заданного, и проб в «плохие» минуты было бы меньше, чем в хорошие.
    if config.request_timeout_ms > config.interval_seconds * 1000:
        raise ValueError(
            f"REQUEST_TIMEOUT_MS ({config.request_timeout_ms}) must not exceed "
            f"PROBE_INTERVAL_SECONDS ({config.interval_seconds} s)"
        )
    return config
