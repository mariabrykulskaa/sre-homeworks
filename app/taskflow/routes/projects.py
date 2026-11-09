"""CRUD проектов: /api/projects."""

from fastapi import APIRouter, Request, Response
from fastapi.responses import JSONResponse

from .. import metrics
from ..errors import HttpError
from ..validate import parse_id, parse_pagination, validate_project
from . import query_params, read_json, serialize

router = APIRouter(prefix="/api/projects")

PROJECT_FIELDS = """
  p.id, p.name, p.description, p.created_at, p.updated_at,
  (SELECT count(*)::int FROM tasks t WHERE t.project_id = p.id) AS task_count
"""


@router.get("")
async def list_projects(request: Request):
    db = request.app.state.db
    limit, offset = parse_pagination(query_params(request))
    # count(*) OVER() — страница и total из одного снимка данных.
    res = await db.query(
        f"""SELECT {PROJECT_FIELDS}, count(*) OVER()::int AS _total FROM projects p
            ORDER BY p.created_at DESC, p.id DESC
            LIMIT %s OFFSET %s""",
        (limit, offset),
    )
    total = res.rows[0]["_total"] if res.rows else 0
    if not res.rows and offset > 0:
        total = (await db.query("SELECT count(*)::int AS total FROM projects")).rows[0]["total"]
    data = [serialize({k: v for k, v in row.items() if k != "_total"}) for row in res.rows]
    return {"data": data, "meta": {"total": total, "limit": limit, "offset": offset}}


@router.get("/{project_id}")
async def get_project(request: Request, project_id: str):
    pid = parse_id(project_id)
    res = await request.app.state.db.query(f"SELECT {PROJECT_FIELDS} FROM projects p WHERE p.id = %s", (pid,))
    if not res.rows:
        raise HttpError(404, "Project not found")
    return {"data": serialize(res.rows[0])}


@router.post("")
async def create_project(request: Request):
    project = validate_project(await read_json(request))
    res = await request.app.state.db.query(
        """INSERT INTO projects (name, description)
           VALUES (%s, %s)
           RETURNING id, name, description, created_at, updated_at, 0 AS task_count""",
        (project["name"], project["description"] or ""),
    )
    metrics.record_project_created()
    return JSONResponse({"data": serialize(res.rows[0])}, status_code=201)


@router.put("/{project_id}")
async def update_project(request: Request, project_id: str):
    pid = parse_id(project_id)
    project = validate_project(await read_json(request), partial=True)
    res = await request.app.state.db.query(
        """UPDATE projects SET
             name        = COALESCE(%s, name),
             description = COALESCE(%s, description),
             updated_at  = now()
           WHERE id = %s
           RETURNING id, name, description, created_at, updated_at,
             (SELECT count(*)::int FROM tasks t WHERE t.project_id = projects.id) AS task_count""",
        (project["name"], project["description"], pid),
    )
    if not res.rows:
        raise HttpError(404, "Project not found")
    return {"data": serialize(res.rows[0])}


@router.delete("/{project_id}")
async def delete_project(request: Request, project_id: str):
    pid = parse_id(project_id)
    # Задачи проекта удаляет сама БД: ON DELETE CASCADE.
    res = await request.app.state.db.query("DELETE FROM projects WHERE id = %s", (pid,))
    if res.rowcount == 0:
        raise HttpError(404, "Project not found")
    metrics.record_project_deleted()
    return Response(status_code=204)
