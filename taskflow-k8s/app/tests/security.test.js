import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';

// Жёсткий лимит, чтобы проверить 429 парой запросов. Переменные ставим
// до импорта приложения (dotenv не перетирает уже заданные значения).
process.env.RATE_LIMIT_PER_MINUTE = '5';
process.env.DATABASE_URL ??= 'postgres://localhost:5432/taskflow_test';

// Та же защита, что и в api.test.js: даже случайно эти тесты
// не должны смотреть на не-тестовую базу.
const testDbName = new URL(process.env.DATABASE_URL).pathname.slice(1);
if (!/^[a-z0-9_]+_test$/.test(testDbName)) {
  throw new Error(`Tests require a "*_test" database, got "${testDbName}"`);
}

const { createApp } = await import('../src/app.js');
const { closePool } = await import('../src/db.js');

let server;
let base;

before(async () => {
  server = createApp().listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await closePool();
});

const SECURITY_HEADERS = [
  'content-security-policy',
  'x-content-type-options',
  'x-frame-options',
  'referrer-policy',
];

test('security-заголовки присутствуют на обычном ответе', async () => {
  const res = await fetch(`${base}/api/health`);
  assert.equal(res.status, 200);
  for (const header of SECURITY_HEADERS) {
    assert.ok(res.headers.get(header), `нет заголовка ${header}`);
  }
  assert.equal(res.headers.get('x-powered-by'), null);
});

test('security-заголовки и rate limit действуют и на ошибках body-parser', async () => {
  const res = await fetch(`${base}/api/projects`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: 'not json',
  });
  assert.equal(res.status, 400);
  for (const header of SECURITY_HEADERS) {
    assert.ok(res.headers.get(header), `нет заголовка ${header} на 400-ответе`);
  }
  // Запрос с битым телом обязан списывать бюджет rate limit'а.
  assert.ok(res.headers.get('ratelimit'), 'нет заголовка RateLimit на 400-ответе');
});

test('health-пробы не тратят бюджет rate limit', async () => {
  for (let i = 0; i < 10; i += 1) {
    assert.equal((await fetch(`${base}/api/health`)).status, 200);
  }
});

test('после исчерпания лимита приходит 429', async () => {
  let last;
  for (let i = 0; i < 6; i += 1) {
    last = await fetch(`${base}/api/nope`); // любой путь под /api, кроме проб
  }
  assert.equal(last.status, 429);
  const body = await last.json();
  assert.equal(body.error, 'Too many requests');
});
