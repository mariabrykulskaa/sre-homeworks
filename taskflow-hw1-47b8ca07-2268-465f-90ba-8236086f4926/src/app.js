import path from 'node:path';
import { fileURLToPath } from 'node:url';
import express from 'express';
import rateLimit from 'express-rate-limit';
import { config } from './config.js';
import { pool } from './db.js';
import { projectsRouter } from './routes/projects.js';
import { tasksRouter } from './routes/tasks.js';
import { notFoundHandler, errorHandler } from './middleware/errors.js';

const publicDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');

const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self'",
  "font-src 'self'",
  "img-src 'self' data:",
  "connect-src 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "base-uri 'self'",
].join('; ');

export function createApp() {
  const app = express();
  app.disable('x-powered-by');

  // Порядок важен: заголовки, лог и rate limit должны видеть КАЖДЫЙ запрос,
  // включая те, что body-parser отклонит (битый JSON, слишком большое тело).
  app.use((req, res, next) => {
    res.set({
      'Content-Security-Policy': CSP,
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'strict-origin-when-cross-origin',
    });
    next();
  });

  // XI. Логи: одна строка JSON на запрос, только в stdout.
  // 'close' вместо 'finish' — оборванные клиентом запросы тоже попадают в лог.
  app.use((req, res, next) => {
    const startedAt = process.hrtime.bigint();
    res.on('close', () => {
      const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
      console.log(JSON.stringify({
        level: 'info',
        msg: 'request',
        method: req.method,
        path: req.originalUrl,
        status: res.writableFinished ? res.statusCode : 499,
        aborted: !res.writableFinished || undefined,
        duration_ms: Math.round(durationMs * 10) / 10,
      }));
    });
    next();
  });

  // Пробы оркестратора не тратят бюджет пользовательского трафика,
  // но и у них есть свой потолок: /api/ready ходит в БД и не должен
  // быть безлимитным путём к пулу соединений.
  const limiterOptions = {
    windowMs: 60_000,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    message: { error: 'Too many requests' },
  };
  const probeLimiter = rateLimit({ ...limiterOptions, limit: 120 });
  const apiLimiter = rateLimit({ ...limiterOptions, limit: config.rateLimit });

  app.use('/api', (req, res, next) => {
    const path = req.path.replace(/\/+$/, '') || '/';
    const isProbe = req.method === 'GET' && (path === '/health' || path === '/ready');
    return (isProbe ? probeLimiter : apiLimiter)(req, res, next);
  });

  app.use(express.json({ limit: '100kb' }));

  // Liveness: процесс жив (без похода в БД, чтобы оркестратор
  // не убивал здоровые реплики при кратком сбое БД).
  app.get('/api/health', (req, res) => {
    res.json({ status: 'ok' });
  });

  // Readiness: готовность обслуживать запросы, включая соединение с БД.
  app.get('/api/ready', async (req, res) => {
    try {
      await pool.query('SELECT 1');
      res.json({ status: 'ready' });
    } catch (err) {
      console.error(JSON.stringify({ level: 'error', msg: 'readiness check failed', error: err.message }));
      res.status(503).json({ status: 'degraded' });
    }
  });

  app.use('/api/projects', projectsRouter);
  app.use('/api/tasks', tasksRouter);

  app.use(express.static(publicDir));

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}
