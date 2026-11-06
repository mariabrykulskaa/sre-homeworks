// Централизованная обработка ошибок: клиент получает аккуратный JSON,
// подробности пишутся в stdout/stderr (XI. Логи — поток событий).
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
  if (res.headersSent) {
    console.error(JSON.stringify({
      level: 'error',
      msg: 'error after headers sent',
      path: req.originalUrl,
      error: err.message,
    }));
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

  console.error(JSON.stringify({
    level: 'error',
    msg: 'unhandled error',
    method: req.method,
    path: req.originalUrl,
    error: err.message,
    stack: err.stack,
  }));
  res.status(500).json({ error: 'Internal server error' });
}
