# TaskFlow

Простое клиент-серверное приложение — трекер задач по проектам.
Бэкенд: Node.js + Express (REST API, HTTP/1.1). Фронтенд: ванильный JS (SPA на одной странице).
Хранилище: PostgreSQL. Приложение построено по методологии [12 факторов](https://12factor.net/ru/) — аргументация в файле [Отчёт.md](Отчёт.md).

## Быстрый старт (Docker)

```bash
docker compose up --build
```

Поднимет PostgreSQL, применит миграции и запустит приложение на <http://localhost:3000>.

## Запуск без Docker

Нужны Node.js ≥ 22 и работающий PostgreSQL.

```bash
# 1. Зависимости
npm ci

# 2. Конфигурация (подставьте свой DATABASE_URL)
cp .env.example .env

# 3. Схема БД (разовый административный процесс)
npm run migrate

# 4. Сервер
npm start
```

## API

Все ответы — JSON в конверте `{ "data": ... }`, ошибки — `{ "error": "..." }`.

| Метод | Путь | Описание |
|---|---|---|
| GET | `/api/health` | Liveness: процесс жив (без похода в БД) |
| GET | `/api/ready` | Readiness: приложение готово, БД доступна (503 — нет) |
| GET | `/api/projects?limit=&offset=` | Список проектов |
| GET | `/api/projects/:id` | Один проект |
| POST | `/api/projects` | Создать проект `{name, description?}` |
| PUT | `/api/projects/:id` | Обновить проект (частичное обновление) |
| DELETE | `/api/projects/:id` | Удалить проект (каскадно с задачами) |
| GET | `/api/tasks?project_id=&status=&limit=&offset=` | Список задач с фильтрами |
| GET | `/api/tasks/:id` | Одна задача |
| POST | `/api/tasks` | Создать задачу `{project_id, title, description?, status?}` |
| PUT | `/api/tasks/:id` | Обновить задачу (частичное обновление) |
| DELETE | `/api/tasks/:id` | Удалить задачу |

Статусы задач: `todo`, `in_progress`, `done`.
Списковые ответы содержат `meta: { total, limit, offset }`; `limit` по умолчанию 100, максимум 500.

Контракт идентификаторов: `id` и `project_id` — BIGINT и сериализуются в JSON **строками** (`"id": "7"`); `task_count` и `meta.total` — числа. Клиент сравнивает идентификаторы как строки.

## Переменные окружения

| Переменная | Обязательная | Описание |
|---|---|---|
| `DATABASE_URL` | да | Строка подключения к PostgreSQL |
| `PORT` | нет (3000) | Порт HTTP-сервера |
| `HOST` | нет (127.0.0.1) | Адрес прослушивания; в контейнере — `0.0.0.0` |
| `RATE_LIMIT_PER_MINUTE` | нет (600) | Лимит запросов к `/api` в минуту с одного адреса, как его видит приложение (за обратным прокси настройте `trust proxy`); пробы `/api/health` и `/api/ready` не учитываются |
| `NODE_ENV` | нет | Окружение (`development` / `production`) |

## Тесты

Юнит-тесты валидации и интеграционные тесты API (встроенный `node:test`, без дополнительных зависимостей):

```bash
npm test
```

Интеграционные тесты используют отдельную БД (по умолчанию `taskflow_test`, создаётся автоматически). Имя базы обязано заканчиваться на `_test` — это защита от случайного запуска тестов на рабочей базе.

## Структура

```
src/
├── server.js        # точка входа, graceful shutdown
├── app.js           # сборка Express-приложения
├── config.js        # чтение и валидация конфигурации из окружения
├── db.js            # пул соединений PostgreSQL
├── migrate.js       # разовый процесс применения миграций
├── lib/validate.js  # валидация входных данных
├── middleware/errors.js
└── routes/          # CRUD: projects, tasks
migrations/          # SQL-миграции
public/              # фронтенд (HTML/CSS/JS, самостоятельно хостящиеся шрифты)
tests/               # юнит- и интеграционные тесты (node:test)
```
