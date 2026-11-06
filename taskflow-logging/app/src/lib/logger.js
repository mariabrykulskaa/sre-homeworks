// XI. Логи — поток событий: одна строка JSON на событие, только в stdout.
// Сбор, доставка и хранение логов — забота окружения (в Kubernetes: kubelet →
// шиппер → Victoria Logs), приложение их никуда не пишет и не ротирует.
//
// Схема записи (общие поля есть у каждой строки):
//   timestamp              RFC 3339 с миллисекундами, UTC
//   level                  debug | info | warn | error
//   message                короткое событие в неизменной формулировке (для поиска)
//   service.name           имя сервиса (SERVICE_NAME, по умолчанию — из package.json)
//   service.version        версия из package.json
//   deployment.environment NODE_ENV
// Остальные поля — контекст события (method, path, status, duration_ms, error.* …).
// Вложенные объекты не используются: плоские имена через точку одинаково
// удобны и человеку, и Victoria Logs, и Grafana.
import { createRequire } from 'node:module';

const pkg = createRequire(import.meta.url)('../../package.json');

export const LOG_LEVELS = Object.freeze(['debug', 'info', 'warn', 'error']);

// Эти ключи задаёт сам логгер; поля вызывающего кода их не перетирают.
const RESERVED = new Set(['timestamp', 'level', 'message', 'service.name', 'service.version', 'deployment.environment']);

// Error не сериализуется JSON.stringify'ем (message и stack — не перечисляемые),
// поэтому раскладываем его в плоские поля сами.
function flattenError(prefix, err) {
  const out = { [`${prefix}.message`]: err.message, [`${prefix}.stack`]: err.stack };
  if (err.code !== undefined) out[`${prefix}.code`] = err.code;
  if (err.name && err.name !== 'Error') out[`${prefix}.type`] = err.name;
  return out;
}

function normalizeFields(fields) {
  const out = {};
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined || RESERVED.has(key)) continue;
    if (value instanceof Error) {
      Object.assign(out, flattenError(key, value));
    } else {
      out[key] = value;
    }
  }
  return out;
}

// LOG_LEVEL из окружения: регистр и пробелы по краям не важны, пустое
// значение (например, `LOG_LEVEL=` в .env) означает «по умолчанию».
// Неизвестное значение остаётся ошибкой — тихо подменять его нельзя.
function normalizeLevel(raw) {
  const value = String(raw ?? '').trim().toLowerCase();
  return value === '' ? 'info' : value;
}

export function createLogger({
  service = process.env.SERVICE_NAME ?? pkg.name,
  version = pkg.version,
  env = process.env.NODE_ENV ?? 'development',
  level = normalizeLevel(process.env.LOG_LEVEL),
  stream = process.stdout,
  now = () => new Date(),
  bindings = {},
} = {}) {
  if (!LOG_LEVELS.includes(level)) {
    throw new Error(`LOG_LEVEL must be one of: ${LOG_LEVELS.join(', ')}, got "${level}"`);
  }
  const threshold = LOG_LEVELS.indexOf(level);
  const base = Object.freeze(normalizeFields(bindings));

  function write(lvl, message, fields) {
    if (LOG_LEVELS.indexOf(lvl) < threshold) return;
    const head = {
      timestamp: now().toISOString(),
      level: lvl,
      message: String(message),
      'service.name': service,
      'service.version': version,
      'deployment.environment': env,
    };
    let line;
    try {
      line = JSON.stringify({ ...head, ...base, ...normalizeFields(fields) });
    } catch (err) {
      // Циклическая ссылка или BigInt в контексте — не повод терять событие
      // и тем более ронять процесс: пишем запись без контекста и причину.
      line = JSON.stringify({ ...head, 'logger.error': err.message });
    }
    stream.write(`${line}\n`);
  }

  const logger = {
    debug: (message, fields = {}) => write('debug', message, fields),
    info: (message, fields = {}) => write('info', message, fields),
    warn: (message, fields = {}) => write('warn', message, fields),
    error: (message, fields = {}) => write('error', message, fields),
    // Дочерний логгер с постоянным контекстом (например, request_id).
    child: (extra) => createLogger({
      service, version, env, level, stream, now, bindings: { ...base, ...extra },
    }),
  };
  return Object.freeze(logger);
}

// Общий экземпляр приложения. Настраивается только окружением (III фактор):
// SERVICE_NAME, NODE_ENV, LOG_LEVEL (debug | info | warn | error, по умолчанию info).
export const logger = createLogger();
