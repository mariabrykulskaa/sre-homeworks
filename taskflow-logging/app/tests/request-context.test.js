import test from 'node:test';
import assert from 'node:assert/strict';
import { requestContext, resolveRequestId, levelForStatus, splitUrl } from '../src/middleware/request-context.js';
import { withServer } from './helpers/http.js';

test('resolveRequestId: принимает безопасный заголовок, иначе генерирует UUID', () => {
  assert.equal(resolveRequestId('abc-123.XYZ_9'), 'abc-123.XYZ_9');
  assert.equal(resolveRequestId(['first', 'second']), 'first');
  for (const bad of [undefined, '', 'a'.repeat(129), 'has space', 'new\nline', 'юникод', '<script>']) {
    assert.match(resolveRequestId(bad), /^[0-9a-f-]{36}$/, String(bad));
  }
});

test('levelForStatus: 5xx — error, 4xx — warn, остальное — info', () => {
  assert.equal(levelForStatus(200), 'info');
  assert.equal(levelForStatus(304), 'info');
  assert.equal(levelForStatus(404), 'warn');
  assert.equal(levelForStatus(499), 'warn');
  assert.equal(levelForStatus(500), 'error');
  assert.equal(levelForStatus(503), 'error');
});

test('splitUrl: путь без «?…»; пустая строка запроса отсутствует, длинная обрезается до 512', () => {
  assert.deepEqual(splitUrl('/x'), { path: '/x', query: undefined });
  assert.deepEqual(splitUrl('/x?'), { path: '/x', query: undefined });
  assert.deepEqual(splitUrl('/x?y=1&z=2'), { path: '/x', query: 'y=1&z=2' });
  assert.deepEqual(splitUrl('/x?a=1?b=2'), { path: '/x', query: 'a=1?b=2' });
  assert.equal(splitUrl(`/x?${'q'.repeat(1000)}`).query.length, 512);
});

const withContext = (handler) => (app, logger) => {
  app.use(requestContext(logger));
  app.use(handler);
};

test('access-лог: одна JSON-запись на запрос с request_id, статусом и длительностью', async () => {
  const records = await withServer(withContext((req, res) => {
    req.log.info('inside handler');
    res.status(201).json({ ok: true });
  }), async (base) => {
    const res = await fetch(`${base}/x?y=1`, { method: 'POST', headers: { 'X-Request-Id': 'req-1' } });
    assert.equal(res.headers.get('x-request-id'), 'req-1');
  });

  assert.equal(records.length, 2);
  const [inner, access] = records;
  assert.equal(inner.message, 'inside handler');
  assert.equal(inner.request_id, 'req-1');
  assert.equal(access.message, 'request');
  assert.equal(access.level, 'info');
  assert.equal(access.request_id, 'req-1');
  assert.equal(access.method, 'POST');
  assert.equal(access.path, '/x');
  assert.equal(access.query, 'y=1');
  assert.equal(access.status, 201);
  assert.equal(typeof access.duration_ms, 'number');
  assert.equal('aborted' in access, false);
  assert.equal('error.message' in access, false);
});

test('access-лог: ответ из смонтированного роутера — путь полный, без query поле отсутствует', async () => {
  const records = await withServer((app, logger) => {
    app.use(requestContext(logger));
    // Внутри роутера req.path === '/' — в лог всё равно должен попасть полный путь.
    app.use('/api/items', (req, res) => res.status(204).end());
  }, async (base) => {
    await fetch(`${base}/api/items`);
  });
  const [access] = records;
  assert.equal(access.path, '/api/items');
  assert.equal('query' in access, false);
  assert.equal(access.status, 204);
});

test('access-лог: 4xx логируется как warn, невалидный X-Request-Id заменяется', async () => {
  const records = await withServer(withContext((req, res) => res.status(404).end()), async (base) => {
    const res = await fetch(base, { headers: { 'X-Request-Id': 'bad id' } });
    assert.match(res.headers.get('x-request-id'), /^[0-9a-f-]{36}$/);
  });
  assert.equal(records[0].level, 'warn');
  assert.equal(records[0].status, 404);
});

test('access-лог: клиент оборвал запрос на середине ответа — 499, warn, aborted', async () => {
  const records = await withServer(withContext((req, res) => {
    // Заголовки и часть тела ушли, конец ответа не наступает — клиент уходит сам.
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.write('partial');
  }), async (base) => {
    const controller = new AbortController();
    const res = await fetch(`${base}/slow`, { signal: controller.signal });
    assert.equal(res.status, 200);
    controller.abort();
    await assert.rejects(res.text());
  });

  assert.equal(records.length, 1);
  const [access] = records;
  assert.equal(access.status, 499);
  assert.equal(access.level, 'warn');
  assert.equal(access.aborted, true);
  assert.equal(access.path, '/slow');
  assert.equal('error.message' in access, false);
});
