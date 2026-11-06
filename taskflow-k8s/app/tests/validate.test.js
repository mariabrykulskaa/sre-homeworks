import test from 'node:test';
import assert from 'node:assert/strict';

const { parseId, parsePagination, validateProject, validateTask, TASK_STATUSES } =
  await import('../src/lib/validate.js');
const { HttpError } = await import('../src/middleware/errors.js');

function httpError(status) {
  return (err) => err instanceof HttpError && err.status === status;
}

test('parseId принимает положительные целые', () => {
  assert.equal(parseId('1'), 1);
  assert.equal(parseId('999999999999999'), 999_999_999_999_999);
});

test('parseId отклоняет ноль, ведущие нули и мусор', () => {
  for (const bad of ['0', '007', '-1', '1.5', 'abc', '', '1 ', ['1', '2'], '9'.repeat(16)]) {
    assert.throws(() => parseId(bad), httpError(400), `ожидался 400 для ${JSON.stringify(bad)}`);
  }
});

test('parsePagination: дефолты, ограничение сверху, offset', () => {
  assert.deepEqual(parsePagination({}), { limit: 100, offset: 0 });
  assert.deepEqual(parsePagination({ limit: '5', offset: '10' }), { limit: 5, offset: 10 });
  assert.deepEqual(parsePagination({ limit: '9999' }), { limit: 500, offset: 0 });
  assert.throws(() => parsePagination({ limit: '0' }), httpError(400));
  assert.throws(() => parsePagination({ offset: '-1' }), httpError(400));
});

test('validateProject: создание требует name', () => {
  assert.deepEqual(validateProject({ name: '  Диплом  ' }), { name: 'Диплом', description: undefined });
  assert.throws(() => validateProject({}), httpError(400));
  assert.throws(() => validateProject({ name: '' }), httpError(400));
  assert.throws(() => validateProject({ name: 42 }), httpError(400));
  assert.throws(() => validateProject(null), httpError(400));
  assert.throws(() => validateProject([]), httpError(400));
});

test('validateProject: null эквивалентен отсутствию поля', () => {
  assert.throws(() => validateProject({ name: null }), httpError(400));
  const partial = validateProject({ name: 'x', description: null }, { partial: true });
  assert.equal(partial.description, undefined);
});

test('validateProject: длина считается в code points', () => {
  const emoji70 = '😀'.repeat(70); // 140 UTF-16-единиц, но 70 символов
  assert.equal(validateProject({ name: emoji70 }).name, emoji70);
  assert.throws(() => validateProject({ name: 'я'.repeat(121) }), httpError(400));
});

test('validateProject: NUL-байты и одинокие суррогаты отклоняются', () => {
  assert.throws(() => validateProject({ name: 'a\u0000b' }), httpError(400));
  assert.throws(() => validateProject({ name: 'a\uD800b' }), httpError(400));
});

test('validateProject: пустой partial-объект отклоняется', () => {
  assert.throws(() => validateProject({}, { partial: true }), httpError(400));
});

test('validateTask: полный набор полей', () => {
  const task = validateTask({ project_id: '7', title: 'T', description: 'd', status: 'done' });
  assert.deepEqual(task, { title: 'T', description: 'd', status: 'done', projectId: 7 });
});

test('validateTask: project_id и title обязательны при создании', () => {
  assert.throws(() => validateTask({ title: 'x' }), httpError(400));
  assert.throws(() => validateTask({ project_id: 1 }), httpError(400));
});

test('validateTask: статус только из списка', () => {
  for (const status of TASK_STATUSES) {
    assert.equal(validateTask({ project_id: 1, title: 'x', status }).status, status);
  }
  assert.throws(() => validateTask({ project_id: 1, title: 'x', status: 'hacked' }), httpError(400));
});

test('validateTask: пустой partial-объект отклоняется, частичный — нет', () => {
  assert.throws(() => validateTask({}, { partial: true }), httpError(400));
  assert.equal(validateTask({ status: 'done' }, { partial: true }).status, 'done');
});
