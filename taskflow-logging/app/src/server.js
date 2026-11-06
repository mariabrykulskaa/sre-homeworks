// VI. Процессы: одно stateless-приложение; VII. Привязка портов: сервис сам
// слушает PORT; IX. Утилизируемость: быстрый старт и корректное завершение.
import { config } from './config.js';
import { createApp } from './app.js';
import { closePool } from './db.js';
import { logger } from './lib/logger.js';
import { installProcessErrorHandlers } from './lib/process-errors.js';

// До всего остального: необработанная ошибка должна попасть в JSON-лог,
// даже если случится при старте.
installProcessErrorHandlers(logger);

const app = createApp();

const server = app.listen(config.port, config.host, () => {
  logger.info('server started', { host: config.host, port: config.port });
});

server.on('error', (err) => {
  logger.error('listen failed', { error: err, host: config.host, port: config.port });
  process.exit(1);
});

let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info('shutting down', { signal });

  // Даём активным запросам завершиться, но не дольше 10 секунд.
  const forceExit = setTimeout(() => {
    logger.error('forced shutdown after timeout', { timeout_ms: 10_000 });
    process.exit(1);
  }, 10_000);
  forceExit.unref();

  server.close(async (err) => {
    if (err) {
      logger.error('error closing server', { error: err });
    }
    try {
      await closePool();
    } catch (poolErr) {
      logger.error('error closing pool', { error: poolErr });
    }
    process.exit(err ? 1 : 0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
