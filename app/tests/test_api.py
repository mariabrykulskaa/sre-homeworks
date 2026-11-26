"""Интеграционные тесты: приложение целиком против настоящего PostgreSQL."""

from taskflow import metrics


def sample(name, **labels):
    return metrics.registry.get_sample_value(name, labels) or 0.0


def requests_count(route, status):
    return sum(
        sample("http_request_duration_seconds_count", method=m, route=route, status_code=str(status))
        for m in ("GET", "POST", "PUT", "DELETE")
    )


def test_health_and_ready(client):
    assert client.get("/api/health").json() == {"status": "ok"}
    assert client.get("/api/ready").json() == {"status": "ready"}


def test_project_crud_and_metrics(client):
    created_before = sample("taskflow_projects_created_total")
    res = client.post("/api/projects", json={"name": "Диплом", "description": "ВКР"})
    assert res.status_code == 201
    project = res.json()["data"]
    assert isinstance(project["id"], str)  # BIGINT — строкой, как ждёт фронтенд
    assert project["task_count"] == 0
    assert project["created_at"].endswith("Z")
    assert sample("taskflow_projects_created_total") == created_before + 1

    pid = project["id"]
    assert client.get(f"/api/projects/{pid}").json()["data"]["description"] == "ВКР"
    updated = client.put(f"/api/projects/{pid}", json={"description": "Выпускная работа"}).json()["data"]
    assert updated["name"] == "Диплом"
    listing = client.get("/api/projects").json()
    assert isinstance(listing["data"], list)
    assert isinstance(listing["meta"]["total"], int)
    assert client.delete(f"/api/projects/{pid}").status_code == 204
    assert client.get(f"/api/projects/{pid}").status_code == 404


def test_task_crud_transitions_filters_and_cascade(client):
    pid = client.post("/api/projects", json={"name": "P"}).json()["data"]["id"]
    transitions_before = sample("taskflow_task_status_transitions_total", **{"from": "todo", "to": "done"})
    lead_before = sample("taskflow_task_lead_time_seconds_count")

    task = client.post("/api/tasks", json={"project_id": pid, "title": "T"}).json()["data"]
    assert task["status"] == "todo"
    assert task["project_id"] == pid
    done = client.put(f"/api/tasks/{task['id']}", json={"status": "done"}).json()["data"]
    assert done["status"] == "done"
    assert sample("taskflow_task_status_transitions_total", **{"from": "todo", "to": "done"}) == transitions_before + 1
    assert sample("taskflow_task_lead_time_seconds_count") == lead_before + 1
    # Переименование без смены статуса — не переход.
    client.put(f"/api/tasks/{task['id']}", json={"title": "T2"})
    assert sample("taskflow_task_status_transitions_total", **{"from": "todo", "to": "done"}) == transitions_before + 1

    assert client.get(f"/api/tasks?project_id={pid}&status=done").json()["meta"]["total"] == 1
    assert client.get(f"/api/tasks?project_id={pid}&status=todo").json()["meta"]["total"] == 0
    client.delete(f"/api/projects/{pid}")
    assert client.get(f"/api/tasks/{task['id']}").json() == {"error": "Task not found"}


def test_validation_and_error_codes(client):
    assert client.post("/api/projects", json={"name": ""}).status_code == 400
    assert client.post("/api/projects", content=b"{bad", headers={"content-type": "application/json"}).json() == {
        "error": "Invalid JSON body"
    }
    assert client.post("/api/projects", content=b"x" * 200_000, headers={"content-type": "application/json"}).status_code == 413
    assert client.get("/api/tasks?status=unknown").status_code == 400
    assert client.get("/api/projects/abc").status_code == 400
    assert client.get("/api/projects/999999").status_code == 404
    assert client.post("/api/tasks", json={"project_id": "999999", "title": "T"}).json() == {
        "error": "Referenced project does not exist"
    }
    assert client.get("/api/nope").json() == {"error": "Not found"}
    assert client.get("/api/projects?limit=1&limit=2").status_code == 400


def test_failed_requests_do_not_touch_business_metrics(client):
    before = sample("taskflow_projects_created_total")
    client.post("/api/projects", json={"name": ""})
    assert sample("taskflow_projects_created_total") == before


def test_http_metrics_use_route_templates(client):
    pid = client.post("/api/projects", json={"name": "P"}).json()["data"]["id"]
    before = requests_count("/api/projects/:id", 200)
    client.get(f"/api/projects/{pid}")
    assert requests_count("/api/projects/:id", 200) == before + 1
    unmatched_before = requests_count("unmatched", 404)
    client.get("/api/nope")
    assert requests_count("unmatched", 404) == unmatched_before + 1


def test_access_log_and_request_id(client):
    res = client.get("/api/health", headers={"x-request-id": "test-req-1"})
    assert res.headers["x-request-id"] == "test-req-1"
    assert res.headers["x-frame-options"] == "DENY"
    record = [r for r in client.logs.records() if r.get("request_id") == "test-req-1"][-1]
    assert record["message"] == "request"
    assert record["level"] == "info"
    assert record["status"] == 200
    assert record["path"] == "/api/health"
    client.get("/api/projects/999999")
    assert client.logs.records()[-1]["level"] == "warn"


def test_version_endpoint_and_identity_headers(make_client):
    from taskflow import __version__

    client = make_client(POD_NAME="taskflow-v2-abc")
    assert client.get("/api/version").json() == {
        "service": "taskflow", "version": __version__, "instance": "taskflow-v2-abc",
    }
    # Версия и реплика — в любом ответе: API, ошибке, статике.
    for path, status in (("/api/projects", 200), ("/api/projects/999999", 404), ("/", 200)):
        res = client.get(path)
        assert res.status_code == status
        assert res.headers["x-app-version"] == __version__
        assert res.headers["x-served-by"] == "taskflow-v2-abc"
    # Host попадает в access-лог: видно, по какому имени запрос пришёл через шлюз.
    client.get("/api/version", headers={"host": "preview.taskflow.local", "x-request-id": "preview-1"})
    record = [r for r in client.logs.records() if r.get("request_id") == "preview-1"][-1]
    assert record["host"] == "preview.taskflow.local"
    assert record["service.version"] == __version__


def test_fault_injection_breaks_data_routes_but_not_probes(make_client):
    faulty = make_client(FAULT_ERROR_RATE="1")
    before = requests_count("/api/projects", 500)
    assert faulty.get("/api/projects").status_code == 500
    assert requests_count("/api/projects", 500) == before + 1  # настоящий шаблон маршрута, не unmatched
    assert faulty.get("/api/health").status_code == 200
    assert faulty.get("/api/ready").status_code == 200
    assert faulty.post("/api/projects", json={"name": ""}).status_code == 400
    errors = [r for r in faulty.logs.records() if r["message"] == "unhandled error"]
    assert errors and errors[-1]["error.type"] == "InjectedFaultError"


def test_rate_limit(make_client):
    limited = make_client(RATE_LIMIT_PER_MINUTE="2")
    statuses = [limited.get("/api/projects").status_code for _ in range(3)]
    assert statuses == [200, 200, 429]
    assert limited.get("/api/health").status_code == 200  # пробы — отдельный бюджет


def test_frontend_is_served(client):
    res = client.get("/")
    assert res.status_code == 200
    assert "<title>" in res.text
    assert res.headers["content-security-policy"].startswith("default-src 'self'")
