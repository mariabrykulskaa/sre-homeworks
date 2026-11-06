// Централизованная обработка ошибок: клиент получает аккуратный JSON,
// подробности уходят в лог запроса (XI. Логи — поток событий).
import { logger } from '../lib/logger.js';

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function notFoundHandler(req, res) {
  res.status(404).json({ error: 'Not found' });
}

// eslint-disable-next-line no-unused-vars
export function errorHandler(err, req, res, next) {
  if (!(err instanceof Error)) {
    err = new Error(typeof err === 'string' ? err : 'Non-error value thrown');
  }

  // Ответ уже начал отправляться — менять статус/заголовки поздно.
  // req.log нет только если ошибка случилась до middleware запроса.
  const log = req.log ?? logger;

  if (res.headersSent) {
    log.error('error after headers sent', { method: req.method, path: req.originalUrl, error: err });
    // Для access-лога это ошибка сервера, а не уход клиента: отмечаем причину
    // обрыва, request-context запишет status 500 вместо 499 (см. outcomeOf).
    res.locals.serverAbort = err;
    res.destroy(err);
    return;
  }

  if (err instanceof HttpError) {
    res.status(err.status).json({ error: err.message });
    return;
  }

  if (err.type === 'entity.parse.failed') {
    res.status(400).json({ error: 'Invalid JSON body' });
    return;
  }

  if (err.type === 'entity.too.large') {
    res.status(413).json({ error: 'Request body too large' });
    return;
  }

  log.error('unhandled error', { method: req.method, path: req.originalUrl, error: err });
  res.status(500).json({ error: 'Internal server error' });
}
