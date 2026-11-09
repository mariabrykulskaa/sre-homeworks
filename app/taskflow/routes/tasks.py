"""CRUD задач: /api/tasks."""

from fastapi import APIRouter, Request, Response
from fastapi.responses import JSONResponse
from psycopg import errors as pg_errors

from .. import metrics
from ..errors import HttpError
from ..metrics import TASK_STATUSES
from ..validate import parse_id, parse_pagination, validate_task
from . import query_params, read_json, serialize

router = APIRouter(prefix="/api/tasks")

TASK_FIELDS = "id, project_id, title, description, status, created_at, updated_at"


def _translate(err: Exception) -> Exception:
    """FK на projects может нарушиться, если проект удалили между проверкой и
    вставкой — переводим ошибку СУБД в понятный ответ клиенту."""
    if isinstance(err, pg_errors.ForeignKeyViolation):
        return HttpError(422, "Referenced project does not exist")
    return err


@router.get("")
async def list_tasks(request: Request):
    db = request.app.state.db
    query = query_params(request)
    where, params = [], []
    if query.get("project_id") is not None:
        params.append(parse_id(query["project_id"], "project_id"))
        where.append("project_id = %s")
    if query.get("status") is not None:
        if query["status"] not in TASK_STATUSES:
            raise HttpError(400, f'"status" must be one of: {", ".join(TASK_STATUSES)}')
        params.append(query["status"])
        where.append("status = %s")
    where_sql = f"WHERE {' AND '.join(where)}" if where else ""
    limit, offset = parse_pagination(query)
    # count(*) OVER() — страница и total из одного снимка данных.
    res = await db.query(
        f"""SELECT {TASK_FIELDS}, count(*) OVER()::int AS _total FROM tasks {where_sql}
            ORDER BY created_at DESC, id DESC
            LIMIT %s OFFSET %s""",
        (*params, limit, offset),
    )
    total = res.rows[0]["_total"] if res.rows else 0
    if not res.rows and offset > 0:
        total = (await db.query(f"SELECT count(*)::int AS total FROM tasks {where_sql}", params)).rows[0]["total"]
    data = [serialize({k: v for k, v in row.items() if k != "_total"}) for row in res.rows]
    return {"data": data, "meta": {"total": total, "limit": limit, "offset": offset}}


@router.get("/{task_id}")
async def get_task(request: Request, task_id: str):
    tid = parse_id(task_id)
    res = await request.app.state.db.query(f"SELECT {TASK_FIELDS} FROM tasks WHERE id = %s", (tid,))
    if not res.rows:
        raise HttpError(404, "Task not found")
    return {"data": serialize(res.rows[0])}


@router.post("")
async def create_task(request: Request):
    task = validate_task(await read_json(request))
    try:
        res = await request.app.state.db.query(
            f"""INSERT INTO tasks (project_id, title, description, status)
                VALUES (%s, %s, %s, %s)
                RETURNING {TASK_FIELDS}""",
            (task["project_id"], task["title"], task["description"] or "", task["status"] or "todo"),
        )
    except pg_errors.Error as err:
        raise _translate(err) from err
    row = res.rows[0]
    metrics.record_task_created(row["status"])
    return JSONResponse({"data": serialize(row)}, status_code=201)


@router.put("/{task_id}")
async def update_task(request: Request, task_id: str):
    tid = parse_id(task_id)
    task = validate_task(await read_json(request), partial=True)
    try:
        # prev — статус до изменения, для метрики переходов. FOR UPDATE блокирует
        # строку, поэтому параллельный UPDATE не вклинится между чтением старого
        # статуса и записью нового: пара (from, to) всегда соответствует истине.
        res = await request.app.state.db.query(
            f"""UPDATE tasks SET
                  title       = COALESCE(%s, title),
                  description = COALESCE(%s, description),
                  status      = COALESCE(%s, status),
                  project_id  = COALESCE(%s, project_id),
                  updated_at  = now()
                FROM (SELECT id AS prev_id, status AS prev_status FROM tasks WHERE id = %s FOR UPDATE) AS prev
                WHERE id = prev.prev_id
                RETURNING {TASK_FIELDS}, prev.prev_status""",
            (task["title"], task["description"], task["status"], task["project_id"], tid),
        )
    except pg_errors.Error as err:
        raise _translate(err) from err
    if not res.rows:
        raise HttpError(404, "Task not found")
    row = dict(res.rows[0])
    previous_status = row.pop("prev_status")
    metrics.record_task_updated(previous_status, row["status"], row["created_at"], row["updated_at"])
    return {"data": serialize(row)}


@router.delete("/{task_id}")
async def delete_task(request: Request, task_id: str):
    tid = parse_id(task_id)
    res = await request.app.state.db.query("DELETE FROM tasks WHERE id = %s RETURNING status", (tid,))
    if not res.rows:
        raise HttpError(404, "Task not found")
    metrics.record_task_deleted(res.rows[0]["status"])
    return Response(status_code=204)
