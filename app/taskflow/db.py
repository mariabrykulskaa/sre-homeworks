"""IV. Сторонние службы: PostgreSQL — прикреплённый ресурс.

Адрес базы задаётся одной переменной DATABASE_URL: замена базы — замена URL,
код не меняется. Пул держит до 10 готовых соединений и переиспользует их.
"""

from dataclasses import dataclass

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from .faults import FaultInjector


@dataclass
class QueryResult:
    rows: list[dict]
    rowcount: int


class Database:
    def __init__(self, url: str, injector: FaultInjector | None = None) -> None:
        self.pool = AsyncConnectionPool(
            url,
            min_size=1,
            max_size=10,
            timeout=5,  # сколько ждать свободное соединение
            max_idle=30,  # простаивающее соединение закрывается через 30 с
            open=False,
            kwargs={
                "autocommit": True,  # каждый запрос — своя транзакция, как в node-pg
                "row_factory": dict_row,
                # сервер сам прерывает слишком долгий запрос
                "options": "-c statement_timeout=5000",
                "connect_timeout": 5,
            },
        )
        self._inject_fault = injector or FaultInjector()

    async def open(self) -> None:
        # wait=False: приложение стартует, даже если БД ещё недоступна;
        # пока её нет, /api/ready отвечает 503 и под не получает трафик.
        await self.pool.open(wait=False)

    async def close(self) -> None:
        await self.pool.close()

    async def query(self, sql: str, params: tuple | list = ()) -> QueryResult:
        """Запросы обработчиков API. Здесь вносятся сбои FAULT_* (faults.py)."""
        await self._inject_fault()
        async with self.pool.connection() as conn:
            cur = await conn.execute(sql, params)
            rows = await cur.fetchall() if cur.description else []
            return QueryResult(rows=rows, rowcount=cur.rowcount)

    async def ping(self) -> None:
        """Проба готовности: в пул напрямую, мимо внесения сбоев."""
        async with self.pool.connection(timeout=2) as conn:
            await conn.execute("SELECT 1")
