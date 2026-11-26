"""Метрики приложения (pull-модель): система мониторинга сама забирает их с
отдельного порта (см. metrics_server.py), приложение никуда их не шлёт.

Формат — OpenMetrics 1.0. Четыре группы:
  рантайм Python   — готовые коллекторы prometheus_client: CPU, память (RSS),
                     открытые дескрипторы, время старта процесса, сборщик мусора
                     по поколениям, версия интерпретатора;
  HTTP (фреймворк) — длительность и число запросов по шаблонам маршрутов
                     (middleware.py);
  бизнес-метрики   — события предметной области (record_* ниже);
  внесённые сбои   — текущие FAULT_* (faults.py), для графиков SLO и алертов.
"""

from datetime import datetime

from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    GCCollector,
    Info,
    PlatformCollector,
    ProcessCollector,
    disable_created_metrics,
)

from . import __version__

TASK_STATUSES = ("todo", "in_progress", "done")

# OpenMetrics-вывод prometheus_client по умолчанию добавляет к каждому счётчику
# ряд *_created (время создания). В хранилище это лишние ряды без пользы.
disable_created_metrics()

# Свой реестр, а не глобальный: в нём ровно то, что описано в этом модуле.
registry = CollectorRegistry()

# Рантайм — готовые коллекторы библиотеки, без собственного кода:
#   process_cpu_seconds_total, process_resident_memory_bytes,
#   process_virtual_memory_bytes, process_open_fds, process_max_fds,
#   process_start_time_seconds                         (ProcessCollector, Linux)
#   python_gc_objects_collected_total{generation},
#   python_gc_objects_uncollectable_total{generation},
#   python_gc_collections_total{generation}            (GCCollector)
#   python_info{version, implementation, ...}           (PlatformCollector)
ProcessCollector(registry=registry)
GCCollector(registry=registry)
PlatformCollector(registry=registry)

# Версия сборки: taskflow_build_info{version="2.1.0"} 1. Во время выкатки
# count by (version) (taskflow_build_info) показывает, сколько реплик какой
# версии сейчас работает (ДЗ №8).
build_info = Info("taskflow_build", "Version of the running TaskFlow build", registry=registry)
build_info.info({"version": __version__})

# HTTP: гистограмма даёт сразу и RPS/ошибки (_count), и перцентили (_bucket).
# Метка route — шаблон маршрута (/api/projects/:id), а не путь с id: иначе каждый
# id порождал бы новый временной ряд. Корзины — те же, что в прошлых ДЗ: на
# границе le="0.25" держится SLI latency.
http_request_duration = Histogram(
    "http_request_duration_seconds",
    "Duration of HTTP requests handled by the API, by route template and status code",
    ["method", "route", "status_code"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
    registry=registry,
)

# Внесённые сбои этой реплики. На графиках рядом с SLI видно, когда и какой сбой
# включён; в обычной работе все три ряда — 0.
fault_error_ratio = Gauge(
    "taskflow_fault_injection_error_ratio",
    "Share of API database queries failed on purpose (FAULT_ERROR_RATE)",
    registry=registry,
)
fault_delay_seconds = Gauge(
    "taskflow_fault_injection_delay_seconds",
    "Delay added before each API database query (FAULT_LATENCY_MS)",
    registry=registry,
)
fault_memory_bytes = Gauge(
    "taskflow_fault_injection_memory_bytes",
    "Memory held on purpose to imitate a leak (FAULT_MEMORY_MB)",
    registry=registry,
)

# --- Бизнес-метрики -----------------------------------------------------------
# Счётчики увеличиваются только после успешного изменения в БД: метрика считает
# произошедшие события, а не попытки. Каждая реплика считает свои события;
# общая картина — sum() по репликам.
projects_created = Counter("taskflow_projects_created", "Projects created", registry=registry)
projects_deleted = Counter(
    "taskflow_projects_deleted", "Projects deleted (their tasks are deleted by cascade)", registry=registry
)
tasks_created = Counter("taskflow_tasks_created", "Tasks created, by initial status", ["status"], registry=registry)
task_status_transitions = Counter(
    "taskflow_task_status_transitions",
    "Task status changes, by previous and new status",
    ["from", "to"],
    registry=registry,
)
# Корзины — от минуты до месяца: задачи живут минуты, часы и дни.
task_lead_time = Histogram(
    "taskflow_task_lead_time_seconds",
    "Time from task creation to its transition to done",
    buckets=(60, 600, 3600, 4 * 3600, 86_400, 3 * 86_400, 7 * 86_400, 30 * 86_400),
    registry=registry,
)
tasks_deleted = Counter(
    "taskflow_tasks_deleted", "Tasks deleted via the API, by status at the moment of deletion", ["status"],
    registry=registry,
)

# Все комбинации меток заводим заранее со значением 0: ряды видны с момента
# старта, а первый инкремент — переход 0 → 1, который increase()/rate() считают.
for _status in TASK_STATUSES:
    tasks_created.labels(status=_status)
    tasks_deleted.labels(status=_status)
    for _to in TASK_STATUSES:
        if _to != _status:
            task_status_transitions.labels(**{"from": _status, "to": _to})


def record_project_created() -> None:
    projects_created.inc()


def record_project_deleted() -> None:
    projects_deleted.inc()


def record_task_created(status: str) -> None:
    tasks_created.labels(status=status).inc()


def record_task_updated(previous_status: str, status: str, created_at: datetime, updated_at: datetime) -> None:
    """Переход статуса и время выполнения (lead time).

    previous_status — статус до UPDATE из той же транзакции (routes/tasks.py).
    Lead time считается по часам БД (created_at → updated_at): обе отметки
    ставит PostgreSQL, а не часы реплики. Переоткрытая и снова закрытая задача
    даёт второе наблюдение — тоже от created_at.
    """
    if previous_status == status:
        return
    task_status_transitions.labels(**{"from": previous_status, "to": status}).inc()
    if status == "done":
        task_lead_time.observe(max(0.0, (updated_at - created_at).total_seconds()))


def record_task_deleted(status: str) -> None:
    tasks_deleted.labels(status=status).inc()
