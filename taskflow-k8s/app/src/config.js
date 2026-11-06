// III. Конфигурация: всё, что меняется между окружениями, читается из
// переменных окружения. .env подхватывается только как удобство для
// локальной разработки (файл в .gitignore и в прод не попадает).
import 'dotenv/config';

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Required environment variable ${name} is not set`);
  }
  return value;
}

export const config = Object.freeze({
  port: Number.parseInt(process.env.PORT ?? '3000', 10),
  // По умолчанию слушаем только loopback: API без аутентификации не должен
  // быть виден всей локальной сети. В контейнере HOST=0.0.0.0 (см. Dockerfile).
  host: process.env.HOST ?? '127.0.0.1',
  databaseUrl: requireEnv('DATABASE_URL'),
  env: process.env.NODE_ENV ?? 'development',
  rateLimit: Number.parseInt(process.env.RATE_LIMIT_PER_MINUTE ?? '600', 10),
});

if (!Number.isInteger(config.port) || config.port <= 0 || config.port > 65535) {
  throw new Error(`PORT must be a valid port number, got "${process.env.PORT}"`);
}

if (!Number.isInteger(config.rateLimit) || config.rateLimit <= 0) {
  throw new Error(`RATE_LIMIT_PER_MINUTE must be a positive integer, got "${process.env.RATE_LIMIT_PER_MINUTE}"`);
}
