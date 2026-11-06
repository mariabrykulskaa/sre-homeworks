// Контекст запроса: идентификатор и access-лог.
//
// request_id: берём из входящего заголовка X-Request-Id (если он похож на
// идентификатор), иначе генерируем. Тот же id возвращаем клиенту и кладём
// в каждую строку лога этого запроса — по нему в Victoria Logs собирается
// вся история одного вызова, а клиент может сослаться на него в обращении.
import { randomUUID } from 'node:crypto';

const REQUEST_ID_RE = /^[A-Za-z0-9._-]{1,128}$/;
// Строка запроса может быть длинной и произвольной — обрезаем, чтобы одна
// запись лога не раздувалась и не ломала батчи шиппера.
const QUERY_MAX_LENGTH = 512;

export function resolveRequestId(header) {
  const value = Array.isArray(header) ? header[0] : header;
  return typeof value === 'string' && REQUEST_ID_RE.test(value) ? value : randomUUID();
}

// 5xx — наша ошибка (error), 4xx — ошибка клиента (warn), остальное — info.
export function levelForStatus(status) {
  if (status >= 500) return 'error';
  if (status >= 400) return 'warn';
  return 'info';
}

// Путь и строка запроса отдельно: по `path` без «?…» удобно группировать
// (`stats by (path)`), а параметры остаются доступны для поиска в `query`.
// Источник — req.originalUrl: req.path/req.baseUrl внутри смонтированного
// роутера урезаны до его точки монтирования и к моменту 'close' не
// восстанавливаются, если ответ отправлен из самого роутера.
export function splitUrl(originalUrl) {
  const idx = originalUrl.indexOf('?');
  if (idx === -1) return { path: originalUrl, query: undefined };
  const query = originalUrl.slice(idx + 1);
  return {
    path: originalUrl.slice(0, idx),
    query: query === '' ? undefined : query.slice(0, QUERY_MAX_LENGTH),
  };
}

// Чем закончился запрос, с точки зрения лога:
//   ответ дописан                     → его статус;
//   ответ оборван сервером (см.
//   errorHandler: ошибка после начала
//   отправки, res.locals.serverAbort) → 500, aborted + error.*;
//   ответ не дописан без нашей ошибки → 499 (клиент ушёл раньше), aborted.
function outcomeOf(res) {
  if (res.locals.serverAbort instanceof Error) {
    return { status: 500, aborted: true, error: res.locals.serverAbort };
  }
  if (res.writableFinished) {
    return { status: res.statusCode, aborted: undefined, error: undefined };
  }
  return { status: 499, aborted: true, error: undefined };
}

export function requestContext(logger) {
  return (req, res, next) => {
    const requestId = resolveRequestId(req.headers['x-request-id']);
    res.set('X-Request-Id', requestId);
    req.log = logger.child({ request_id: requestId });

    const startedAt = process.hrtime.bigint();
    // 'close' вместо 'finish' — оборванные запросы тоже попадают в лог.
    res.on('close', () => {
      const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
      const { status, aborted, error } = outcomeOf(res);
      const { path, query } = splitUrl(req.originalUrl);
      req.log[levelForStatus(status)]('request', {
        method: req.method,
        path,
        query,
        status,
        aborted,
        duration_ms: Math.round(durationMs * 10) / 10,
        client_ip: req.ip,
        error,
      });
    });
    next();
  };
}
