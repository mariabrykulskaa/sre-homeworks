import { Router } from 'express';
import { pool } from '../db.js';
import { HttpError } from '../middleware/errors.js';
import { parseId, parsePagination, validateTask, TASK_STATUSES } from '../lib/validate.js';

export const tasksRouter = Router();

const TASK_FIELDS = 'id, project_id, title, description, status, created_at, updated_at';

// FK на projects может нарушиться, если проект удалили между проверкой и вставкой —
// переводим ошибку СУБД в понятный ответ клиенту.
function translateDbError(err) {
  if (err.code === '23503') {
    return new HttpError(422, 'Referenced project does not exist');
  }
  return err;
}

tasksRouter.get('/', async (req, res) => {
  const where = [];
  const params = [];

  if (req.query.project_id !== undefined) {
    params.push(parseId(req.query.project_id, 'project_id'));
    where.push(`project_id = $${params.length}`);
  }
  if (req.query.status !== undefined) {
    if (!TASK_STATUSES.includes(req.query.status)) {
      throw new HttpError(400, `"status" must be one of: ${TASK_STATUSES.join(', ')}`);
    }
    params.push(req.query.status);
    where.push(`status = $${params.length}`);
  }

  const whereSql = where.length > 0 ? `WHERE ${where.join(' AND ')}` : '';
  const { limit, offset } = parsePagination(req.query);
  // count(*) OVER() — страница и total из одного снимка данных.
  const { rows } = await pool.query(
    `SELECT ${TASK_FIELDS}, count(*) OVER()::int AS _total FROM tasks ${whereSql}
     ORDER BY created_at DESC, id DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, limit, offset],
  );
  let total = rows.length > 0 ? rows[0]._total : 0;
  if (rows.length === 0 && offset > 0) {
    ({ rows: [{ total }] } = await pool.query(
      `SELECT count(*)::int AS total FROM tasks ${whereSql}`,
      params,
    ));
  }
  const data = rows.map(({ _total, ...row }) => row);
  res.json({ data, meta: { total, limit, offset } });
});

tasksRouter.get('/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const { rows } = await pool.query(
    `SELECT ${TASK_FIELDS} FROM tasks WHERE id = $1`,
    [id],
  );
  if (rows.length === 0) throw new HttpError(404, 'Task not found');
  res.json({ data: rows[0] });
});

tasksRouter.post('/', async (req, res) => {
  const { title, description, status, projectId } = validateTask(req.body);
  try {
    const { rows } = await pool.query(
      `INSERT INTO tasks (project_id, title, description, status)
       VALUES ($1, $2, $3, $4)
       RETURNING ${TASK_FIELDS}`,
      [projectId, title, description ?? '', status ?? 'todo'],
    );
    res.status(201).json({ data: rows[0] });
  } catch (err) {
    throw translateDbError(err);
  }
});

tasksRouter.put('/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const { title, description, status, projectId } = validateTask(req.body, { partial: true });
  let rows;
  try {
    ({ rows } = await pool.query(
      `UPDATE tasks SET
         title       = COALESCE($2, title),
         description = COALESCE($3, description),
         status      = COALESCE($4, status),
         project_id  = COALESCE($5, project_id),
         updated_at  = now()
       WHERE id = $1
       RETURNING ${TASK_FIELDS}`,
      [id, title ?? null, description ?? null, status ?? null, projectId ?? null],
    ));
  } catch (err) {
    throw translateDbError(err);
  }
  if (rows.length === 0) throw new HttpError(404, 'Task not found');
  res.json({ data: rows[0] });
});

tasksRouter.delete('/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const { rowCount } = await pool.query('DELETE FROM tasks WHERE id = $1', [id]);
  if (rowCount === 0) throw new HttpError(404, 'Task not found');
  res.status(204).end();
});
