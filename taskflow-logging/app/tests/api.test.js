import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

// Интеграционные тесты ходят в отдельную БД. Устанавливаем URL до импорта
// приложения; dotenv не перетирает уже заданные переменные окружения.
process.env.DATABASE_URL ??= 'postgres://localhost:5432/taskflow_test';
// Access-лог и ожидаемые ошибки (400/404/500) не засоряют вывод тестов.
process.env.LOG_LEVEL ??= 'error';

const dbUrl = new URL(process.env.DATABASE_URL);
const dbName = dbUrl.pathname.slice(1);
if (!/^[a-z0-9_]+_test$/.test(dbName)) {
  throw new Error(
    `Integration tests require a database whose name ends with "_test", got "${dbName}". ` +
    'Set DATABASE_URL to a disposable test database.',
  );
}

const { createApp } = await import('../src/app.js');
const { pool, closePool } = await import('../src/db.js');

const execFileAsync = promisify(execFile);
let server;
let base;

before(async () => {
  // Создаём тестовую БД, если её нет (через служебную БД postgres).
  const adminUrl = new URL(process.env.DATABASE_URL);
  adminUrl.pathname = '/postgres';
  const admin = new pg.Client({ connectionString: adminUrl.toString() });
  await admin.connect();
  const { rowCount } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [dbName]);
  if (rowCount === 0) {
    await admin.query(`CREATE DATABASE "${dbName}"`);
  }
  await admin.end();

  const migratePath = fileURLToPath(new URL('../src/migrate.js', import.meta.url));
  await execFileAsync('node', [migratePath], {
    env: { ...process.env, DATABASE_URL: process.env.DATABASE_URL },
  });
  await pool.query('TRUNCATE tasks, projects RESTART IDENTITY CASCADE');

  server = createApp().listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await closePool();
});

async function call(method, path, body) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: body === undefined ? undefined : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

test('GET /api/health и /api/ready отвечают 200', async () => {
  assert.equal((await call('GET', '/api/health')).status, 200);
  const ready = await call('GET', '/api/ready');
  assert.equal(ready.status, 200);
  assert.equal(ready.body.status, 'ready');
});

test('каждый ответ несёт X-Request-Id; корректный входящий id возвращается как есть', async () => {
  const generated = await fetch(`${base}/api/health`);
  assert.match(generated.headers.get('x-request-id'), /^[0-9a-f-]{36}$/);

  const echoed = await fetch(`${base}/api/projects/999999`, { headers: { 'X-Request-Id': 'trace-42' } });
  assert.equal(echoed.status, 404);
  assert.equal(echoed.headers.get('x-request-id'), 'trace-42');
});

test('CRUD проекта: создание, чтение, обновление, удаление', async () => {
  const created = await call('POST', '/api/projects', { name: 'Диплом', description: 'ВКР' });
  assert.equal(created.status, 201);
  const id = created.body.data.id;
  assert.equal(created.body.data.name, 'Диплом');
  assert.equal(created.body.data.task_count, 0);

  const got = await call('GET', `/api/projects/${id}`);
  assert.equal(got.status, 200);
  assert.equal(got.body.data.description, 'ВКР');

  const updated = await call('PUT', `/api/projects/${id}`, { description: 'Выпускная работа' });
  assert.equal(updated.status, 200);
  assert.equal(updated.body.data.name, 'Диплом');
  assert.equal(updated.body.data.description, 'Выпускная работа');

  const list = await call('GET', '/api/projects');
  assert.equal(list.status, 200);
  assert.ok(Array.isArray(list.body.data));
  assert.equal(typeof list.body.meta.total, 'number');

  const del = await call('DELETE', `/api/projects/${id}`);
  assert.equal(del.status, 204);
  assert.equal((await call('GET', `/api/projects/${id}`)).status, 404);
});

test('CRUD задачи, фильтры и каскадное удаление', async () => {
  const project = (await call('POST', '/api/projects', { name: 'P' })).body.data;

  const task = await call('POST', '/api/tasks', {
    project_id: project.id,
    title: 'Сделать',
    status: 'in_progress',
  });
  assert.equal(task.status, 201);
  assert.equal(task.body.data.status, 'in_progress');
  assert.equal(task.body.data.project_id, project.id);

  const filtered = await call('GET', `/api/tasks?project_id=${project.id}&status=in_progress`);
  assert.equal(filtered.body.data.length, 1);
  assert.equal(filtered.body.meta.total, 1);

  const empty = await call('GET', `/api/tasks?project_id=${project.id}&status=done`);
  assert.equal(empty.body.data.length, 0);

  const moved = await call('PUT', `/api/tasks/${task.body.data.id}`, { status: 'done' });
  assert.equal(moved.body.data.status, 'done');

  // Каскад: удаление проекта удаляет его задачи.
  await call('DELETE', `/api/projects/${project.id}`);
  assert.equal((await call('GET', `/api/tasks/${task.body.data.id}`)).status, 404);
});

test('валидация и коды ошибок', async () => {
  assert.equal((await call('POST', '/api/projects', { name: '' })).status, 400);
  assert.equal((await call('POST', '/api/projects', [])).status, 400);
  assert.equal((await call('GET', '/api/projects/abc')).status, 400);
  assert.equal((await call('GET', '/api/projects/0')).status, 400);
  assert.equal((await call('GET', '/api/projects/424242')).status, 404);
  assert.equal((await call('PUT', '/api/projects/424242', {})).status, 400); // пустой PATCH
  assert.equal((await call('POST', '/api/tasks', { project_id: 424242, title: 'x' })).status, 422);
  assert.equal((await call('GET', '/api/tasks?status=hacked')).status, 400);
  assert.equal((await call('GET', '/api/nope')).status, 404);

  const badJson = await fetch(`${base}/api/projects`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: 'not json',
  });
  assert.equal(badJson.status, 400);

  const huge = await call('POST', '/api/projects', { name: 'x'.repeat(200_000) });
  assert.equal(huge.status, 413);
});

test('пагинация: limit/offset и meta', async () => {
  const p = (await call('POST', '/api/projects', { name: 'Pager' })).body.data;
  for (let i = 0; i < 5; i += 1) {
    await call('POST', '/api/tasks', { project_id: p.id, title: `t${i}` });
  }
  const page = await call('GET', `/api/tasks?project_id=${p.id}&limit=2&offset=2`);
  assert.equal(page.body.data.length, 2);
  assert.deepEqual(page.body.meta, { total: 5, limit: 2, offset: 2 });
  assert.equal((await call('GET', '/api/tasks?limit=0')).status, 400);
  await call('DELETE', `/api/projects/${p.id}`);
});
