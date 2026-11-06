// IV. Сторонние службы: PostgreSQL — прикреплённый ресурс, адрес которого
// задаётся одной переменной окружения DATABASE_URL. Замена базы = замена URL.
import pg from 'pg';
import { config } from './config.js';
import { logger } from './lib/logger.js';

export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
  statement_timeout: 5_000, // сервер прерывает слишком долгий запрос
  query_timeout: 6_000, // клиентская страховка поверх серверного таймаута
});

pool.on('error', (err) => {
  // Ошибки простаивающих соединений не должны ронять процесс.
  logger.error('idle client error', { error: err });
});

export async function closePool() {
  await pool.end();
}
