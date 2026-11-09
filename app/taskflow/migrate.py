"""XII. Административные задачи: миграции схемы БД — разовый процесс.

Запуск: python -m taskflow.migrate — тот же образ, тот же код и та же
конфигурация (DATABASE_URL), что и у приложения.

  * применённые миграции записываются в таблицу schema_migrations — повторный
    запуск ничего не делает (идемпотентность);
  * каждая миграция применяется в транзакции — упала посередине, откатилась целиком;
  * advisory-блокировка PostgreSQL: несколько реплик, стартующих одновременно,
    не применят одну миграцию дважды.
"""

import os
import sys
from pathlib import Path

import psycopg
from dotenv import load_dotenv

from .logger import logger

MIGRATIONS_DIR = Path(__file__).resolve().parent.parent / "migrations"
# Произвольная константа, общая для всех экземпляров раннера этого приложения.
MIGRATION_LOCK_ID = 728301


def migrate(conn: psycopg.Connection, log) -> None:
    files = sorted(p for p in MIGRATIONS_DIR.iterdir() if p.suffix == ".sql")
    conn.execute("SELECT pg_advisory_lock(%s)", (MIGRATION_LOCK_ID,))
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                name       TEXT PRIMARY KEY,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """)
        for path in files:
            if conn.execute("SELECT 1 FROM schema_migrations WHERE name = %s", (path.name,)).fetchone():
                log.info("migration skipped", migration=path.name, reason="already applied")
                continue
            with conn.transaction():
                conn.execute(path.read_text(encoding="utf-8"))
                conn.execute("INSERT INTO schema_migrations (name) VALUES (%s)", (path.name,))
            log.info("migration applied", migration=path.name)
    finally:
        conn.execute("SELECT pg_advisory_unlock(%s)", (MIGRATION_LOCK_ID,))


def main() -> None:
    load_dotenv()
    # Те же поля, что у сервера, плюс component — чтобы в хранилище логов
    # отличать разовый админ-процесс от основного контейнера.
    log = logger.child(component="migrate")
    url = os.environ.get("DATABASE_URL")
    if not url:
        log.error("migration failed", error=ValueError("Required environment variable DATABASE_URL is not set"))
        sys.exit(1)
    try:
        # Отдельное соединение без statement_timeout рабочего пула:
        # долгая миграция (построение индекса) не должна обрываться.
        with psycopg.connect(url, autocommit=True, connect_timeout=10) as conn:
            migrate(conn, log)
    except Exception as err:  # noqa: BLE001
        log.error("migration failed", error=err)
        sys.exit(1)
    log.info("migrations up to date")


if __name__ == "__main__":
    main()
