# SRE — домашние задания

Приложение **TaskFlow** — трекер задач (**Python 3.13 + FastAPI**, PostgreSQL 17) и его эксплуатация
в minikube. Одна кодовая база для всех заданий:

| Каталог | Что внутри |
|---|---|
| [`app/`](app/) | приложение TaskFlow 2.0: REST API + фронтенд, JSON-логи, метрики, внесение сбоев, тесты (pytest), Dockerfile, docker-compose |
| [`prober/`](prober/) | пробер: синтетические сценарии пользователя для SLI (asyncio + httpx), тесты |

Домашние задания:

| ДЗ | Каталог | Тема | Отчёт |
|---|---|---|---|
| 1 | [`taskflow-hw1/`](taskflow-hw1/) | приложение по 12 факторам | [Отчёт.md](taskflow-hw1/Отчёт.md) |
| 2 | [`taskflow-k8s/`](taskflow-k8s/) | Kubernetes (minikube): StatefulSet, Deployment, Service, ConfigMap, Secret | [Отчёт.md](taskflow-k8s/Отчёт.md) |
| 3 | [`taskflow-logging/`](taskflow-logging/) | логи: Victoria Logs + Vector, LogsQL, алерты по логам | [Отчёт.md](taskflow-logging/Отчёт.md) |
| 4 | [`taskflow-metrics/`](taskflow-metrics/) | метрики: VictoriaMetrics + vmagent, рантайм Python, бизнес-метрики, postgres-exporter | [Отчёт.md](taskflow-metrics/Отчёт.md) |
| 5 | [`taskflow-sla/`](taskflow-sla/) | SLI, SLO, SLA: пробер, правила vmalert, дашборд Grafana | [Отчёт.md](taskflow-sla/Отчёт.md) |
| 6 | [`taskflow-alerts/`](taskflow-alerts/) | алерты на метрики сервиса и рантайма Python, Alertmanager, уведомления на почту | [Отчёт.md](taskflow-alerts/Отчёт.md) |
| 7 | [`taskflow-grafana/`](taskflow-grafana/) | Grafana: RED, рантайм Python, SLA пробера, импорт PostgreSQL Exporter | [Отчёт.md](taskflow-grafana/Отчёт.md) |

Инструкции по запуску — в `README.md` каждого каталога. Архив для сдачи собирает
`scripts/make-archive.sh` в каталоге задания; для Grafana — `python3 scripts/make-archive.py`.
Исходники `app/` и `prober/` копируются в архив.

Первая версия приложения была на Node.js + Express — она в ветке `main`.
