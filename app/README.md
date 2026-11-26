# TaskFlow 2.1 (Python)

Простое клиент-серверное приложение — трекер задач по проектам.
Бэкенд: **Python 3.13 + FastAPI** (REST API, HTTP/1.1), сервер **uvicorn**.
Фронтенд: ванильный JS (SPA на одной странице, `public/`). Хранилище: **PostgreSQL 17**.
Приложение построено по методологии [12 факторов](https://12factor.net/ru/) — аргументация в
[../taskflow-hw1/Отчёт.md](../taskflow-hw1/Отчёт.md).

Одна кодовая база для всех домашних заданий: логи (ДЗ №3), метрики (ДЗ №4), внесение сбоев
(ДЗ №5–6) — здесь же.

## Быстрый старт (Docker)

```bash
docker compose up --build
```

Поднимет PostgreSQL, применит миграции (разовый сервис `migrate`) и запустит приложение на
<http://localhost:3000>. Документация API (генерирует FastAPI): <http://localhost:3000/docs>.

## Запуск без Docker

Нужны Python ≥ 3.12 и работающий PostgreSQL.

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt     # 1. зависимости (версии зафиксированы)
cp .env.example .env                # 2. конфигурация — подставьте свой DATABASE_URL
python -m taskflow.migrate          # 3. схема БД — разовый административный процесс
python -m taskflow.server           # 4. сервер
```

## Тесты

```bash
pip install -r requirements-dev.txt
DATABASE_URL=postgres://taskflow:taskflow@localhost:5432/taskflow_test python -m pytest
```

Юнит-тесты (проверка данных, сбои, конфигурация, логгер, сервер метрик) и интеграционные тесты
API против настоящего PostgreSQL. База для тестов должна называться `*_test` — тесты создают её
сами и очищают таблицы.

## API

Все ответы — JSON в конверте `{ "data": ... }`, ошибки — `{ "error": "..." }`.
Идентификаторы (`BIGINT`) приходят строками: `"id": "7"`.

| Метод | Путь | Описание |
|---|---|---|
| GET | `/api/health` | Liveness: процесс жив (без похода в БД) |
| GET | `/api/ready` | Readiness: приложение готово, БД доступна (503 — нет) |
| GET | `/api/version` | Версия сборки и реплика: `{service, version, instance}` |
| GET | `/api/projects?limit=&offset=` | Список проектов |
| GET | `/api/projects/{id}` | Один проект |
| POST | `/api/projects` | Создать проект `{name, description?}` |
| PUT | `/api/projects/{id}` | Обновить проект (частичное обновление) |
| DELETE | `/api/projects/{id}` | Удалить проект (каскадно с задачами) |
| GET | `/api/tasks?project_id=&status=&limit=&offset=` | Список задач с фильтрами |
| GET | `/api/tasks/{id}` | Одна задача |
| POST | `/api/tasks` | Создать задачу `{project_id, title, description?, status?}` |
| PUT | `/api/tasks/{id}` | Обновить задачу (частичное обновление) |
| DELETE | `/api/tasks/{id}` | Удалить задачу |

Коды ответов: `200`, `201`, `204`; `400` — ошибка валидации или битый JSON; `404` — не найдено;
`413` — слишком большое тело; `422` — ссылка на несуществующий проект; `429` — превышен лимит
запросов; `500` — внутренняя ошибка; `503` — БД недоступна (только `/api/ready`).

Метрики (OpenMetrics) — `GET /metrics` на отдельном порту `METRICS_PORT` (9464).

Версия и реплика видны в каждом ответе — заголовки `X-App-Version` и `X-Served-By` (имя пода),
в каждой строке лога — поле `service.version`, в метриках — `taskflow_build_info{version}`.
Версию задаёт сборка образа: `docker build --build-arg APP_VERSION=2.2.0 …` (по умолчанию —
версия исходников, `taskflow/__init__.py`). Выкатка двух версий через Envoy Gateway —
[../taskflow-deploy/](../taskflow-deploy/).

## Структура

```
taskflow/
  server.py          точка входа: запуск uvicorn и сервера метрик, корректная остановка
  app.py             сборка приложения: middleware, маршруты, health/ready, статика
  config.py          настройки из переменных окружения (III фактор)
  db.py              пул соединений с PostgreSQL (IV фактор)
  middleware.py      request_id, access-лог, HTTP-метрики, обработка ошибок, лимит запросов
  validate.py        проверка входных данных
  routes/            CRUD проектов и задач
  logger.py          JSON-логи в stdout (XI фактор)
  metrics.py         метрики рантайма Python, HTTP и бизнес-метрики
  metrics_server.py  отдельный HTTP-сервер /metrics
  faults.py          внесение сбоев для демонстрации SLO и алертов
  migrate.py         миграции схемы — разовый процесс (XII фактор)
migrations/          SQL-миграции
public/              фронтенд
tests/               pytest
```

## Конфигурация

Все настройки — переменные окружения, полный список с пояснениями — в [.env.example](.env.example):
`DATABASE_URL` (обязательно), `PORT`, `HOST`, `APP_ENV`, `RATE_LIMIT_PER_MINUTE`, `LOG_LEVEL`,
`SERVICE_NAME`, `METRICS_PORT`, `FAULT_ERROR_RATE`, `FAULT_LATENCY_MS`, `FAULT_MEMORY_MB`,
`POD_NAME` (имя реплики для `X-Served-By`; в Kubernetes — из Downward API).
