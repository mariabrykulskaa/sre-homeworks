# TaskFlow: логирование в Victoria Logs (minikube)

Домашнее задание №3. В кластер minikube из ДЗ №2 добавлены **Victoria Logs**
(single-node) и шиппер **Vector** (DaemonSet), приложение TaskFlow переведено на структурированные
JSON-логи. Запросы LogsQL со скриншотами и объяснение выбранной схемы доставки — в [Отчёт.md](Отчёт.md).

## Состав

```
k8s/
  app/                   манифесты приложения из ДЗ №2 (образ taskflow:1.1 с JSON-логами, LOG_LEVEL)
  logging/
    00-namespace.yaml    Namespace logging (PSA privileged — шипперу нужны hostPath и root)
    10-victoria-logs.yaml PVC + Deployment + Service Victoria Logs (порт 9428, vmui на /select/vmui/)
    20-vector-rbac.yaml  ServiceAccount + ClusterRole (list/watch pods, namespaces, nodes)
    21-vector-config.yaml ConfigMap: kubernetes_logs → remap (разбор JSON) → elasticsearch-sink в Victoria Logs
    22-vector-daemonset.yaml DaemonSet Vector с hostPath /var/log/pods и /var/lib/docker/containers
    30-alertmanager.yaml (бонус) Alertmanager: ConfigMap + Deployment + Service, порт 9093
    31-vmalert.yaml      (бонус) vmalert: LogsQL-правила в ConfigMap + Deployment + Service, порт 8880
scripts/
  lib.sh                 общие переменные и пути для скриптов (подключается через source)
  build-image.sh         сборка образа приложения демоном minikube
  deploy.sh              kubectl apply k8s/app + k8s/logging и ожидание готовности
  port-forward.sh        туннели до Victoria Logs (9428), vmalert (8880) и Alertmanager (9093)
  generate-traffic.sh    трафик к приложению (успехи, ошибки клиента, по флагу — сбой БД)
  run-queries.sh         LogsQL-запросы из отчёта через HTTP API
  screenshot-vmui.sh     скриншот vmui с запросом (headless Chrome) — так сделаны картинки в отчёте
  screenshot-url.sh      скриншот произвольной страницы headless Chrome
  screenshot-ui.mjs      скриншот после клика («Expand All» в vmalert/Alertmanager), через playwright-core
  destroy.sh             удаление стека логирования (--purge-node-state — и чекпоинтов Vector на узле)
  make-archive.sh        архив для сдачи
screenshots/             скриншоты vmui для отчёта
app/                     (в архиве) исходники приложения с Dockerfile
```

Исходники приложения — в соседнем каталоге `../homework1` (одна кодовая база для всех заданий).
Для этого задания в них добавлен логгер `src/lib/logger.js` и middleware
`src/middleware/request-context.js`; скрипты сами находят `app/Dockerfile` в распакованном архиве
(переопределить — переменной `APP_DIR`).

## Быстрый старт

```bash
minikube start --driver=docker --container-runtime=docker

scripts/build-image.sh            # taskflow:1.1 внутри minikube
scripts/deploy.sh                 # приложение + Victoria Logs + Vector, ждёт готовности

scripts/port-forward.sh           # в отдельном терминале; vmui: http://127.0.0.1:9428/select/vmui/
                                  # vmalert: http://127.0.0.1:8880/vmalert/  Alertmanager: http://127.0.0.1:9093/
scripts/generate-traffic.sh --db-outage   # наполнить логи: info/warn и error во время сбоя БД
scripts/run-queries.sh 30         # те же запросы, что в отчёте, за последние 30 минут
```

## Формат логов приложения

Одна строка JSON на событие, только stdout. Общие поля каждой записи:

| Поле | Пример | Откуда |
|---|---|---|
| `timestamp` | `2026-10-16T16:12:20.563Z` | RFC 3339, UTC |
| `level` | `info` / `warn` / `error` / `debug` | порог — `LOG_LEVEL` |
| `message` | `request`, `unhandled error` | неизменная формулировка события |
| `service.name` | `taskflow` | `SERVICE_NAME` или `name` из package.json |
| `service.version` | `1.1.0` | `version` из package.json |
| `deployment.environment` | `production` | `NODE_ENV` |

Контекст события — плоскими полями: у access-лога `request_id`, `method`, `path` (без строки
запроса), `query` (строка запроса после `?`, до 512 символов; поля нет, если её не было), `status`,
`duration_ms`, `client_ip`; у ошибок `error.message`, `error.stack`, `error.code`. Уровень
access-лога зависит от статуса: 5xx — `error`, 4xx — `warn`, остальное — `info`. `request_id`
берётся из заголовка `X-Request-Id` (или генерируется) и возвращается клиенту тем же заголовком.

```bash
kubectl logs -n taskflow deploy/taskflow -c taskflow --tail=3   # убедиться, что это JSON
```

## Путь логов

```
под taskflow ──stdout──► kubelet: /var/log/pods/taskflow_<pod>_<uid>/<container>/0.log
                                  (симлинк в /var/lib/docker/containers/<id>/<id>-json.log)
                                        │  hostPath, только чтение
                                        ▼
                         Vector (DaemonSet, logging): kubernetes_logs → remap → elasticsearch
                                        │  POST http://victoria-logs.logging.svc:9428/insert/elasticsearch/_bulk
                                        ▼
                         Victoria Logs (Deployment + PVC, logging) ──► vmui /select/vmui/, LogsQL API /select/logsql/query
```

При приёме Victoria Logs переименовывает `message` → `_msg`, `timestamp` → `_time`, а поток `_stream`
образуют `kubernetes.namespace`, `kubernetes.pod`, `kubernetes.container`, `stream`
(параметры `_msg_field`, `_time_field`, `_stream_fields` в конфигурации Vector).

## Бонус: алерты по логам (vmalert)

vmalert (`k8s/logging/31-vmalert.yaml`) раз в 30 секунд выполняет LogsQL-правила прямо по Victoria Logs
(эндпоинт `/select/logsql/stats_query`) и отправляет сработавшие алерты в Alertmanager
(`k8s/logging/30-alertmanager.yaml`). Правила — в ConfigMap `vmalert-rules`:

| Алерт | Запрос | Порог |
|---|---|---|
| `TaskflowErrorLogs` | `_time:5m service.name:taskflow level:error \| stats by (kubernetes.pod) count() as errors` | `errors > 0` в течение 1 мин |
| `TaskflowHigh5xxRate` | доля ответов `status >= 500` среди `_msg:request` за 5 минут | `> 5 %` в течение 1 мин |

```bash
scripts/generate-traffic.sh --db-outage     # создать ошибки
curl -s http://127.0.0.1:8880/api/v1/alerts  # через 1–2 минуты: state=firing
open http://127.0.0.1:8880/vmalert/          # UI vmalert: правила, состояние, последние вычисления
open http://127.0.0.1:9093/                  # UI Alertmanager: активные алерты
```

Изменили правила — поменяйте аннотацию `rules.revision` в Deployment vmalert или сделайте
`kubectl rollout restart deploy/vmalert -n logging`.

## Полезные команды

```bash
kubectl get pods,pvc -n logging
kubectl logs -n logging ds/vector | grep -v '"level":"INFO"'    # проблемы доставки
kubectl exec -n logging ds/vector -- vector top                 # поток событий по компонентам
curl -s http://127.0.0.1:9428/select/logsql/query --data-urlencode 'query=service.name:taskflow level:error | limit 5'
curl -s http://127.0.0.1:9428/select/logsql/field_names --data-urlencode 'query=*'   # какие поля есть
```

Изменили `21-vector-config.yaml` — поменяйте аннотацию `config.revision` в DaemonSet (или
`kubectl rollout restart ds/vector -n logging`): ConfigMap сам по себе поды не перезапускает.

## Удаление

```bash
scripts/destroy.sh                 # Victoria Logs, Vector, vmalert, Alertmanager, RBAC (данные на PVC удаляются)
scripts/destroy.sh --purge-node-state   # то же + rm -rf /var/lib/vector на узле (minikube ssh)
kubectl delete -f k8s/app/         # приложение и база (как в ДЗ №2)
```

Без `--purge-node-state` чекпоинты Vector остаются на узле в `/var/lib/vector` (hostPath): после
повторного `deploy.sh` Vector продолжит с запомненных позиций в файлах и **не перечитает** старые
строки в свежий, пустой Victoria Logs — `read_from: beginning` действует только для файлов, о
которых чекпоинтов ещё нет.
