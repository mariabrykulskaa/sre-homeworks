# TaskFlow: метрики в VictoriaMetrics (minikube)

Домашнее задание №4. В кластер minikube из прошлых заданий добавлены **VictoriaMetrics** (single-node)
и **vmagent** из официальных Helm-чартов, приложение TaskFlow (Python) отдаёт метрики рантайма Python,
HTTP и бизнес-метрики, в под PostgreSQL добавлен **postgres-exporter**. Всё собирается через
service discovery по аннотациям `prometheus.io/*`. Описание стека, экспортеров и бизнес-метрик —
в [Отчёт.md](Отчёт.md).

## Состав

```
k8s/
  app/                     манифесты приложения из ДЗ №3 с изменениями для метрик:
    01-configmap.yaml      + METRICS_PORT=9464
    10-postgres.yaml       + sidecar postgres-exporter (:9187) и аннотации prometheus.io/*
    20-app.yaml            образ taskflow:2.0, порт metrics (:9464), аннотации prometheus.io/*
  monitoring/
    00-namespace.yaml      namespace monitoring (Pod Security: restricted)
    vmsingle-values.yaml   values чарта vm/victoria-metrics-single 0.49.0 — хранилище
    vmagent-values.yaml    values чарта vm/victoria-metrics-agent 0.50.0 — сбор (kubernetes_sd, role: pod)
    rendered/              (в архиве) итоговые манифесты чартов — helm template с теми же values
scripts/
  lib.sh                   общие переменные: namespace'ы, версии чартов, имена Service'ов, порты
  build-image.sh           сборка образа taskflow:2.0 docker-демоном minikube
  deploy.sh                helm upgrade --install VictoriaMetrics и vmagent + kubectl apply приложения
  port-forward.sh          туннели к VictoriaMetrics (8428) и vmagent (8429)
  generate-traffic.sh      трафик к приложению: проекты, задачи, переходы статусов, ошибки 4xx
  check-metrics.sh         проверка сбора: таргеты vmagent, up, рантайм, HTTP, бизнес, PostgreSQL
  demo.sh                  сценарий скринкаста (команды из задания + проверки)
  record-screencast.sh     запись скринкаста: asciinema → agg → MP4
  screenshot-vmui.sh       скриншот vmui с MetricsQL-запросом (так сделаны графики в отчёте)
  screenshot-url.sh        скриншот страницы headless-Chrome'ом (/targets vmagent)
  destroy.sh               удаление мониторинга (helm uninstall + namespace)
  make-archive.sh          архив для сдачи
screenshots/               скриншоты vmui и vmagent для отчёта
screencast/                скринкаст: screencast.mp4 и исходная запись screencast.cast
app/                       (в архиве) исходники приложения с Dockerfile
```

Исходники приложения (Python) — в соседнем каталоге `../app` (одна кодовая база для всех заданий).
Метрики — `taskflow/metrics.py` (реестр, рантайм, HTTP-гистограмма, бизнес-метрики),
`taskflow/metrics_server.py` (отдельный сервер `/metrics`), HTTP-метрика пишется в
`taskflow/middleware.py`; миграция `migrations/002_monitoring_role.sql` заводит роль для экспортера.
Скрипты сами находят `app/Dockerfile` в распакованном архиве (переопределить — переменной `APP_DIR`).

## Быстрый старт

Нужны minikube, kubectl, helm (v3 или v4), curl, jq, python3.

```bash
minikube start --driver=docker --container-runtime=docker

scripts/build-image.sh            # taskflow:2.0 внутри minikube
scripts/deploy.sh                 # VictoriaMetrics + vmagent (Helm), приложение и БД с экспортером

scripts/port-forward.sh           # в отдельном терминале: :8428 VictoriaMetrics, :8429 vmagent
scripts/generate-traffic.sh       # наполнить бизнес-метрики; через 15 с их заберёт vmagent
scripts/check-metrics.sh          # все проверки; раздел — аргументом: targets|up|runtime|http|business|postgres
```

UI: vmui — <http://127.0.0.1:8428/vmui/>, таргеты vmagent — <http://127.0.0.1:8429/targets>.

## Команды проверки из задания

Имена Service'ов совпадают с командами из задания:

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
kubectl port-forward svc/vm-single-victoria-metrics-single-server -n monitoring 8428:8428
kubectl port-forward svc/vm-single-victoria-metrics-agent -n monitoring 8429:8429
curl "http://localhost:8428/api/v1/label/__name__/values"
curl "http://localhost:8428/api/v1/query?query=up"
curl "http://localhost:8429/metrics"
```

## Как устроен сбор

```
поды с аннотациями prometheus.io/scrape: "true"
  ├─ taskflow (×2)     :9464/metrics   prometheus_client: рантайм Python, HTTP, бизнес-метрики
  ├─ db-0              :9187/metrics   postgres-exporter (sidecar рядом с PostgreSQL)
  ├─ vm-single-…-0     :8428/metrics   сама VictoriaMetrics
  └─ vmagent           :8429/metrics   сам vmagent
        ▲ pull, каждые 15 с
        │
vmagent (Deployment, monitoring) ── kubernetes_sd_configs: role: pod ── API Kubernetes
        │ remote write
        ▼
VictoriaMetrics single (StatefulSet + PVC 4 Gi, monitoring) ── /api/v1/query, vmui /vmui/
```

Подключить к мониторингу новое приложение — значит добавить в шаблон пода три аннотации
(`prometheus.io/scrape`, `prometheus.io/port`, `prometheus.io/path`) и объявить этот порт в `ports`
контейнера; конфигурацию vmagent менять не нужно.

## Удаление

```bash
scripts/destroy.sh                 # релизы vm-agent и vm-single, namespace monitoring (с PVC метрик)
kubectl delete -f k8s/app/         # приложение и база (как в ДЗ №2)
```
