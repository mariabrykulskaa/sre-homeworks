import test from 'node:test';
import assert from 'node:assert/strict';
import { createLogger, LOG_LEVELS } from '../src/lib/logger.js';

// Поток-заглушка: собирает всё, что логгер записал бы в stdout.
function captureStream() {
  const chunks = [];
  return {
    write(chunk) { chunks.push(String(chunk)); return true; },
    lines: () => chunks.join('').split('\n').filter(Boolean),
    records: () => chunks.join('').split('\n').filter(Boolean).map((l) => JSON.parse(l)),
  };
}

const fixedNow = () => new Date('2026-10-16T12:00:00.123Z');

function makeLogger(overrides = {}) {
  const stream = captureStream();
  const log = createLogger({
    service: 'taskflow',
    version: '1.0.0',
    env: 'test',
    level: 'info',
    stream,
    now: fixedNow,
    ...overrides,
  });
  return { log, stream };
}

test('пишет одну строку JSON с обязательными полями чек-листа', () => {
  const { log, stream } = makeLogger();
  log.info('server started', { port: 3000 });

  const lines = stream.lines();
  assert.equal(lines.length, 1);
  assert.deepEqual(JSON.parse(lines[0]), {
    timestamp: '2026-10-16T12:00:00.123Z',
    level: 'info',
    message: 'server started',
    'service.name': 'taskflow',
    'service.version': '1.0.0',
    'deployment.environment': 'test',
    port: 3000,
  });
});

test('каждая запись заканчивается переводом строки (одна запись — одна строка)', () => {
  const { log, stream } = makeLogger();
  log.info('a');
  log.warn('b');
  const raw = stream.lines();
  assert.equal(raw.length, 2);
  assert.equal(raw.map((l) => JSON.parse(l).message).join(''), 'ab');
});

test('записи ниже порога отбрасываются', () => {
  const { log, stream } = makeLogger({ level: 'warn' });
  log.debug('d');
  log.info('i');
  log.warn('w');
  log.error('e');
  assert.deepEqual(stream.records().map((r) => r.level), ['warn', 'error']);
});

test('неизвестный уровень в конфигурации — ошибка при создании', () => {
  assert.throws(() => makeLogger({ level: 'verbose' }), /LOG_LEVEL/);
  assert.deepEqual(LOG_LEVELS, ['debug', 'info', 'warn', 'error']);
});

test('ошибки раскладываются в плоские поля error.*', () => {
  const { log, stream } = makeLogger();
  const err = new Error('boom');
  err.code = 'ECONNREFUSED';
  log.error('db failed', { error: err });

  const [rec] = stream.records();
  assert.equal(rec['error.message'], 'boom');
  assert.equal(rec['error.code'], 'ECONNREFUSED');
  assert.match(rec['error.stack'], /^Error: boom\n/);
  assert.equal(rec.error, undefined);
});

test('служебные поля нельзя перетереть пользовательскими', () => {
  const { log, stream } = makeLogger();
  log.info('msg', { level: 'debug', message: 'other', timestamp: 'x', 'service.name': 'evil' });
  const [rec] = stream.records();
  assert.equal(rec.level, 'info');
  assert.equal(rec.message, 'msg');
  assert.equal(rec.timestamp, '2026-10-16T12:00:00.123Z');
  assert.equal(rec['service.name'], 'taskflow');
});

test('child добавляет связанные поля ко всем записям', () => {
  const { log, stream } = makeLogger();
  const reqLog = log.child({ request_id: 'abc' });
  reqLog.info('request');
  reqLog.child({ extra: 1 }).warn('nested');
  const [a, b] = stream.records();
  assert.equal(a.request_id, 'abc');
  assert.equal(b.request_id, 'abc');
  assert.equal(b.extra, 1);
});

test('несериализуемые поля не роняют процесс', () => {
  const { log, stream } = makeLogger();
  const circular = {};
  circular.self = circular;
  assert.doesNotThrow(() => log.info('weird', { circular, big: 10n }));
  const [rec] = stream.records();
  assert.equal(rec.message, 'weird');
  assert.equal(rec.level, 'info');
  assert.match(rec['logger.error'], /circular|BigInt/i);
});

test('поля со значением undefined не попадают в запись', () => {
  const { log, stream } = makeLogger();
  log.info('m', { a: undefined, b: null, c: 0 });
  const [rec] = stream.records();
  assert.equal('a' in rec, false);
  assert.equal(rec.b, null);
  assert.equal(rec.c, 0);
});

test('LOG_LEVEL из окружения нормализуется: регистр, пробелы, пустая строка → info', () => {
  const saved = process.env.LOG_LEVEL;
  try {
    for (const [raw, expected] of [[' WARN ', 'warn'], ['Error', 'error'], ['', 'info'], ['  ', 'info']]) {
      process.env.LOG_LEVEL = raw;
      const stream = captureStream();
      const log = createLogger({ stream, now: fixedNow });
      log.debug('d'); log.info('i'); log.warn('w'); log.error('e');
      const first = stream.records()[0]?.level;
      assert.equal(first, expected, `LOG_LEVEL=${JSON.stringify(raw)}`);
    }
    process.env.LOG_LEVEL = 'verbose';
    assert.throws(() => createLogger({ stream: captureStream() }), /LOG_LEVEL/);
  } finally {
    if (saved === undefined) delete process.env.LOG_LEVEL; else process.env.LOG_LEVEL = saved;
  }
});
