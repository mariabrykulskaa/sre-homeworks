// Вспомогательные функции для тестов middleware: логгер с перехватом вывода
// и временный HTTP-сервер на свободном порту.
import express from 'express';
import { createLogger } from '../../src/lib/logger.js';

// Поток-заглушка вместо stdout. Access-запись пишется в обработчике 'close'
// ответа — позже, чем клиент получил ответ, поэтому вместо ожидания «на глаз»
// отдаём промис, который разрешается первой записью с message === 'request'.
export function captureStream() {
  const records = [];
  let resolveAccess;
  const accessLogged = new Promise((resolve) => { resolveAccess = resolve; });
  return {
    records,
    accessLogged,
    write(chunk) {
      for (const line of String(chunk).split('\n').filter(Boolean)) {
        const record = JSON.parse(line);
        records.push(record);
        if (record.message === 'request') resolveAccess(record);
      }
      return true;
    },
  };
}

export function testLogger(stream) {
  return createLogger({ service: 't', version: '0', env: 'test', level: 'info', stream });
}

// Сколько ждать access-запись. Обычно она приходит за миллисекунды; лимит нужен
// только чтобы регрессия в middleware валила тест, а не вешала `node --test`.
const ACCESS_LOG_TIMEOUT_MS = 5000;

// Ограничивает ожидание промиса: по истечении ms отклоняется с message.
// Таймер снят с учёта (unref), чтобы не держать процесс после разрешения промиса.
export function withTimeout(promise, ms, message) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), ms);
    timer.unref();
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

// Поднимает приложение, построенное setup(app, logger), вызывает fn(baseUrl),
// дожидается access-записи и возвращает все записи лога.
export async function withServer(setup, fn) {
  const stream = captureStream();
  const app = express();
  setup(app, testLogger(stream));
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  try {
    await fn(`http://127.0.0.1:${server.address().port}`);
    await withTimeout(
      stream.accessLogged,
      ACCESS_LOG_TIMEOUT_MS,
      `Access-запись (message === 'request') не появилась за ${ACCESS_LOG_TIMEOUT_MS} мс`,
    );
  } finally {
    // Оборванные соединения иначе держали бы server.close() до таймаута.
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
  return stream.records;
}
