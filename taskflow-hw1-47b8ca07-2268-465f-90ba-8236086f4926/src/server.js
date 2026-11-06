// VI. Процессы: одно stateless-приложение; VII. Привязка портов: сервис сам
// слушает PORT; IX. Утилизируемость: быстрый старт и корректное завершение.
import { config } from './config.js';
import { createApp } from './app.js';
import { closePool } from './db.js';

const app = createApp();

const server = app.listen(config.port, config.host, () => {
  console.log(JSON.stringify({
    level: 'info',
    msg: 'server started',
    host: config.host,
    port: config.port,
    env: config.env,
  }));
});

server.on('error', (err) => {
  console.error(JSON.stringify({ level: 'error', msg: 'listen failed', error: err.message }));
  process.exit(1);
});

let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(JSON.stringify({ level: 'info', msg: 'shutting down', signal }));

  // Даём активным запросам завершиться, но не дольше 10 секунд.
  const forceExit = setTimeout(() => {
    console.error(JSON.stringify({ level: 'error', msg: 'forced shutdown after timeout' }));
    process.exit(1);
  }, 10_000);
  forceExit.unref();

  server.close(async (err) => {
    if (err) {
      console.error(JSON.stringify({ level: 'error', msg: 'error closing server', error: err.message }));
    }
    try {
      await closePool();
    } catch (poolErr) {
      console.error(JSON.stringify({ level: 'error', msg: 'error closing pool', error: poolErr.message }));
    }
    process.exit(err ? 1 : 0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
