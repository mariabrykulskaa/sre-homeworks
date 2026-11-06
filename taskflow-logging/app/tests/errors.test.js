import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import { requestContext } from '../src/middleware/request-context.js';
import { errorHandler, HttpError } from '../src/middleware/errors.js';
import { withServer } from './helpers/http.js';

// Маленькое приложение с настоящими middleware запроса и ошибок.
const appWith = (routes) => (app, logger) => {
  app.use(requestContext(logger));
  app.use(express.json({ limit: '64b' }));
  routes(app);
  app.use(errorHandler);
};

const accessOf = (records) => records.find((r) => r.message === 'request');

test('errorHandler: HttpError → её статус и сообщение, без записи об ошибке', async () => {
  let body;
  const records = await withServer(appWith((app) => {
    app.get('/teapot', () => { throw new HttpError(418, 'I am a teapot'); });
  }), async (base) => {
    const res = await fetch(`${base}/teapot`);
    assert.equal(res.status, 418);
    body = await res.json();
  });
  assert.deepEqual(body, { error: 'I am a teapot' });
  assert.equal(records.length, 1);
  assert.equal(accessOf(records).status, 418);
  assert.equal(accessOf(records).level, 'warn');
});

test('errorHandler: битый JSON → 400 Invalid JSON body', async () => {
  let res;
  await withServer(appWith((app) => {
    app.post('/items', (req, r) => r.json(req.body));
  }), async (base) => {
    res = await fetch(`${base}/items`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{broken',
    });
  });
  assert.equal(res.status, 400);
  assert.deepEqual(await res.json(), { error: 'Invalid JSON body' });
});

test('errorHandler: тело больше лимита → 413 Request body too large', async () => {
  let res;
  await withServer(appWith((app) => {
    app.post('/items', (req, r) => r.json(req.body));
  }), async (base) => {
    res = await fetch(`${base}/items`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pad: 'x'.repeat(200) }),
    });
  });
  assert.equal(res.status, 413);
  assert.deepEqual(await res.json(), { error: 'Request body too large' });
});

test('errorHandler: неожиданная ошибка → 500 без деталей клиенту, подробности в лог с request_id', async () => {
  let body;
  const records = await withServer(appWith((app) => {
    app.get('/boom', () => { throw new Error('db exploded'); });
  }), async (base) => {
    const res = await fetch(`${base}/boom`, { headers: { 'X-Request-Id': 'req-500' } });
    assert.equal(res.status, 500);
    body = await res.json();
  });
  assert.deepEqual(body, { error: 'Internal server error' });

  const [unhandled, access] = records;
  assert.equal(unhandled.message, 'unhandled error');
  assert.equal(unhandled.level, 'error');
  assert.equal(unhandled.request_id, 'req-500');
  assert.equal(unhandled['error.message'], 'db exploded');
  assert.match(unhandled['error.stack'], /^Error: db exploded\n/);
  assert.equal(access.status, 500);
  assert.equal(access.level, 'error');
});

test('errorHandler: ошибка после отправки заголовков — обрыв ответа, в access-логе 500/error/aborted', async () => {
  const records = await withServer(appWith((app) => {
    app.get('/stream', (req, res, next) => {
      res.write('partial');
      next(new Error('x'));
    });
  }), async (base) => {
    // Заголовки могли дойти, а могли и нет — важно лишь, что ответ не завершён.
    await fetch(`${base}/stream`).then((res) => res.text()).catch(() => undefined);
  });

  const [afterHeaders, access] = records;
  assert.equal(afterHeaders.message, 'error after headers sent');
  assert.equal(afterHeaders.level, 'error');
  assert.equal(afterHeaders['error.message'], 'x');
  assert.equal(access.message, 'request');
  assert.equal(access.status, 500);
  assert.equal(access.level, 'error');
  assert.equal(access.aborted, true);
  assert.equal(access['error.message'], 'x');
  assert.equal(access.path, '/stream');
});
