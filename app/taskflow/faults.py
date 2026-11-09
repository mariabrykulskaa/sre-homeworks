"""Внесение сбоев (fault injection) для демонстрации SLO и алертов.

Управляемо ухудшаем поведение приложения, чтобы на графиках SLI/SLO и в
алертах было видно, как сбой расходует бюджет ошибок. По умолчанию всё
выключено; включается переменными окружения (III фактор):

  FAULT_ERROR_RATE  доля (0…1) запросов к БД из обработчиков API, которые
                    завершаются ошибкой — клиент получает 500;
  FAULT_LATENCY_MS  задержка в миллисекундах перед каждым таким запросом;
  FAULT_MEMORY_MB   сколько мегабайт памяти процесс занимает «балластом» при
                    старте — имитация утечки памяти для алерта на рантайм.

Сбой вносится на уровне доступа к данным (db.query), а не в HTTP-обработчике:
ошибка возникает внутри маршрута, как настоящая, поэтому в HTTP-метриках у неё
настоящий шаблон маршрута (/api/tasks/:id), а не route="unmatched". Проба
готовности (/api/ready) ходит в пул напрямую и сбоям не подвержена — иначе
внесённые ошибки выводили бы реплики из балансировки.
"""

import asyncio
import random
import re

MAX_FAULT_LATENCY_MS = 30_000
MAX_FAULT_MEMORY_MB = 1024

# Только десятичная запись: «0x10» или «1e» не должны молча превратиться в число.
_DECIMAL = re.compile(r"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$")


class InjectedFaultError(Exception):
    """Ошибка, внесённая намеренно; по code отличается в логах от настоящих."""

    code = "FAULT_INJECTED"

    def __init__(self) -> None:
        super().__init__("Injected fault (FAULT_ERROR_RATE)")


def _parse_number(raw: str | None) -> float | None:
    value = (raw or "").strip()
    if value == "":
        return 0.0  # пустое значение — «выключено», как и отсутствие переменной
    return float(value) if _DECIMAL.match(value) else None


def parse_error_rate(raw: str | None) -> float:
    rate = _parse_number(raw)
    if rate is None or not 0 <= rate <= 1:
        raise ValueError(f'FAULT_ERROR_RATE must be a number from 0 to 1, got "{raw}"')
    return rate


def _parse_int(raw: str | None, name: str, maximum: int) -> int:
    value = _parse_number(raw)
    if value is None or not value.is_integer() or not 0 <= value <= maximum:
        raise ValueError(f'{name} must be an integer from 0 to {maximum}, got "{raw}"')
    return int(value)


def parse_latency_ms(raw: str | None) -> int:
    return _parse_int(raw, "FAULT_LATENCY_MS", MAX_FAULT_LATENCY_MS)


def parse_memory_mb(raw: str | None) -> int:
    return _parse_int(raw, "FAULT_MEMORY_MB", MAX_FAULT_MEMORY_MB)


class FaultInjector:
    """Вызывается перед каждым запросом к БД: ждёт latency_ms и с
    вероятностью error_rate бросает InjectedFaultError."""

    def __init__(self, error_rate: float = 0.0, latency_ms: int = 0, rng=random.random) -> None:
        self.error_rate = error_rate
        self.latency_ms = latency_ms
        self._rng = rng

    async def __call__(self) -> None:
        if self.latency_ms > 0:
            await asyncio.sleep(self.latency_ms / 1000)
        if self.error_rate > 0 and self._rng() < self.error_rate:
            raise InjectedFaultError()


def allocate_memory_ballast(megabytes: int) -> bytes:
    """Занимает megabytes МБ резидентной памяти и возвращает объект-балласт.

    bytes, заполненные единицами, а не bytearray(n): нулевая память из calloc
    не попадает в RSS, пока её не тронут, и алерт на память бы не сработал.
    """
    return b"\x01" * (megabytes * 1024 * 1024)
