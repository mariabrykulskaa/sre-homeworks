import { Router } from 'express';
import { pool } from '../db.js';
import { HttpError } from '../middleware/errors.js';
import { parseId, parsePagination, validateProject } from '../lib/validate.js';

export const projectsRouter = Router();

const PROJECT_FIELDS = `
  p.id, p.name, p.description, p.created_at, p.updated_at,
  (SELECT count(*)::int FROM tasks t WHERE t.project_id = p.id) AS task_count
`;

projectsRouter.get('/', async (req, res) => {
  const { limit, offset } = parsePagination(req.query);
  // count(*) OVER() — страница и total из одного снимка данных.
  const { rows } = await pool.query(
    `SELECT ${PROJECT_FIELDS}, count(*) OVER()::int AS _total FROM projects p
     ORDER BY p.created_at DESC, p.id DESC
     LIMIT $1 OFFSET $2`,
    [limit, offset],
  );
  let total = rows.length > 0 ? rows[0]._total : 0;
  if (rows.length === 0 && offset > 0) {
    ({ rows: [{ total }] } = await pool.query('SELECT count(*)::int AS total FROM projects'));
  }
  const data = rows.map(({ _total, ...row }) => row);
  res.json({ data, meta: { total, limit, offset } });
});

projectsRouter.get('/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const { rows } = await pool.query(
    `SELECT ${PROJECT_FIELDS} FROM projects p WHERE p.id = $1`,
    [id],
  );
  if (rows.length === 0) throw new HttpError(404, 'Project not found');
  res.json({ data: rows[0] });
});

projectsRouter.post('/', async (req, res) => {
  const { name, description } = validateProject(req.body);
  const { rows } = await pool.query(
    `INSERT INTO projects (name, description)
     VALUES ($1, $2)
     RETURNING id, name, description, created_at, updated_at, 0 AS task_count`,
    [name, description ?? ''],
  );
  res.status(201).json({ data: rows[0] });
});

projectsRouter.put('/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const { name, description } = validateProject(req.body, { partial: true });
  const { rows } = await pool.query(
    `UPDATE projects SET
       name        = COALESCE($2, name),
       description = COALESCE($3, description),
       updated_at  = now()
     WHERE id = $1
     RETURNING id, name, description, created_at, updated_at,
       (SELECT count(*)::int FROM tasks t WHERE t.project_id = projects.id) AS task_count`,
    [id, name ?? null, description ?? null],
  );
  if (rows.length === 0) throw new HttpError(404, 'Project not found');
  res.json({ data: rows[0] });
});

projectsRouter.delete('/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const { rowCount } = await pool.query('DELETE FROM projects WHERE id = $1', [id]);
  if (rowCount === 0) throw new HttpError(404, 'Project not found');
  res.status(204).end();
});
