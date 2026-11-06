import { HttpError } from '../middleware/errors.js';

export const TASK_STATUSES = Object.freeze(['todo', 'in_progress', 'done']);

export function parseId(raw, name = 'id') {
  // До 15 цифр — заведомо меньше Number.MAX_SAFE_INTEGER; без нуля и ведущих нулей.
  if (!/^[1-9]\d{0,14}$/.test(String(raw))) {
    throw new HttpError(400, `${name} must be a positive integer`);
  }
  return Number.parseInt(raw, 10);
}

export function parsePagination(query, { defaultLimit = 100, maxLimit = 500, maxOffset = 100_000 } = {}) {
  let limit = defaultLimit;
  let offset = 0;
  if (query.limit !== undefined) {
    limit = Math.min(parseId(query.limit, 'limit'), maxLimit);
  }
  if (query.offset !== undefined) {
    if (!/^\d{1,15}$/.test(String(query.offset))) {
      throw new HttpError(400, 'offset must be a non-negative integer');
    }
    offset = Number.parseInt(query.offset, 10);
    // Огромный OFFSET заставляет СУБД сканировать и выбрасывать строки.
    if (offset > maxOffset) {
      throw new HttpError(400, `offset must be at most ${maxOffset}`);
    }
  }
  return { limit, offset };
}

function requireObject(body) {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new HttpError(400, 'Request body must be a JSON object');
  }
}

// Единая политика: явный null эквивалентен отсутствию поля.
function cleanString(value, field, { required, maxLength }) {
  if (value === undefined || value === null) {
    if (required) throw new HttpError(400, `"${field}" is required`);
    return undefined;
  }
  if (typeof value !== 'string') {
    throw new HttpError(400, `"${field}" must be a string`);
  }
  const trimmed = value.trim();
  if (trimmed.includes('\u0000')) {
    throw new HttpError(400, `"${field}" must not contain NUL characters`);
  }
  // Одинокие суррогаты Node молча заменил бы на U+FFFD при записи в БД.
  if (!trimmed.isWellFormed()) {
    throw new HttpError(400, `"${field}" must be well-formed Unicode`);
  }
  if (required && trimmed.length === 0) {
    throw new HttpError(400, `"${field}" must not be empty`);
  }
  // Считаем code points, как char_length() в PostgreSQL, а не UTF-16-единицы.
  if ([...trimmed].length > maxLength) {
    throw new HttpError(400, `"${field}" must be at most ${maxLength} characters`);
  }
  return trimmed;
}

function requireAnyField(entity, fields) {
  if (fields.every((f) => entity[f] === undefined)) {
    throw new HttpError(400, 'No fields to update');
  }
}

// partial = true для PATCH-семантики: отсутствующие поля не трогаем.
export function validateProject(body, { partial = false } = {}) {
  requireObject(body);
  const project = {
    name: cleanString(body.name, 'name', { required: !partial, maxLength: 120 }),
    description: cleanString(body.description, 'description', { required: false, maxLength: 2000 }),
  };
  if (partial && project.name !== undefined && project.name.length === 0) {
    throw new HttpError(400, '"name" must not be empty');
  }
  if (partial) requireAnyField(project, ['name', 'description']);
  return project;
}

export function validateTask(body, { partial = false } = {}) {
  requireObject(body);
  const task = {
    title: cleanString(body.title, 'title', { required: !partial, maxLength: 200 }),
    description: cleanString(body.description, 'description', { required: false, maxLength: 5000 }),
    status: undefined,
    projectId: undefined,
  };
  if (partial && task.title !== undefined && task.title.length === 0) {
    throw new HttpError(400, '"title" must not be empty');
  }
  if (body.status !== undefined && body.status !== null) {
    if (!TASK_STATUSES.includes(body.status)) {
      throw new HttpError(400, `"status" must be one of: ${TASK_STATUSES.join(', ')}`);
    }
    task.status = body.status;
  }
  if (body.project_id !== undefined && body.project_id !== null) {
    task.projectId = parseId(body.project_id, 'project_id');
  } else if (!partial) {
    throw new HttpError(400, '"project_id" is required');
  }
  if (partial) requireAnyField(task, ['title', 'description', 'status', 'projectId']);
  return task;
}
