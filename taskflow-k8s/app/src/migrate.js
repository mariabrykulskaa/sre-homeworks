// XII. Административные задачи: миграции запускаются как разовый процесс
// (`npm run migrate`) в том же окружении и с тем же кодом, что и приложение.
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { config } from './config.js';

const migrationsDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'migrations');

// Произвольная константа, общая для всех экземпляров раннера этого приложения.
const MIGRATION_LOCK_ID = 728301;

async function migrate(client) {
  const files = (await readdir(migrationsDir))
    .filter((f) => f.endsWith('.sql'))
    .sort();

  try {
    // Advisory-блокировка: два одновременных запуска (например, две реплики
    // на старте) не попытаются применить одну и ту же миграцию дважды.
    await client.query('SELECT pg_advisory_lock($1)', [MIGRATION_LOCK_ID]);
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        name       TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    `);

    for (const file of files) {
      const { rowCount } = await client.query(
        'SELECT 1 FROM schema_migrations WHERE name = $1',
        [file],
      );
      if (rowCount > 0) {
        console.log(`skip  ${file} (already applied)`);
        continue;
      }

      const sql = await readFile(path.join(migrationsDir, file), 'utf8');
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query('INSERT INTO schema_migrations (name) VALUES ($1)', [file]);
        await client.query('COMMIT');
        console.log(`apply ${file}`);
      } catch (err) {
        await client.query('ROLLBACK');
        throw err;
      }
    }
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [MIGRATION_LOCK_ID]).catch(() => {});
  }
}

// Выделенный клиент без statement/query-таймаутов рабочего пула:
// долгая миграция (backfill, построение индекса) не должна обрываться.
const client = new pg.Client({ connectionString: config.databaseUrl });

try {
  await client.connect();
  await migrate(client);
  console.log('migrations up to date');
} catch (err) {
  console.error(`migration failed: ${err.message}`);
  process.exitCode = 1;
} finally {
  await client.end().catch((err) => {
    console.error(`failed to close connection: ${err.message}`);
  });
}
