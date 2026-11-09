# TaskFlow: SLI, SLO и SLA (minikube)

Домашнее задание №5. К мониторингу из ДЗ №4 (VictoriaMetrics single и vmagent) добавлены:

- **пробер** `taskflow-prober` — внешний клиент, который раз в 5 секунд проходит сценарии
  пользователя через Service TaskFlow и отдаёт их итог метриками;
- **vmalert** с правилами SLO: считает SLI по минутам, долю ошибок в окнах 5m…30d, остаток бюджета
  ошибок, скорость его расходования и алерты по ней, а также общую доступность для SLA;
- **Grafana** с дашбордом «TaskFlow — SLI, SLO, SLA»;
- в приложение — **внесение сбоев** (`FAULT_ERROR_RATE`, `FAULT_LATENCY_MS`) для демонстрации.

Выбор метрик, формулировки и формулы SLI/SLO/SLA, сценарий скринкаста — в [Отчёт.md](Отчёт.md).

## Состав

```
k8s/
  app/                       манифесты приложения из ДЗ №4; образ taskflow:2.0 (внесение сбоев)
  monitoring/
    00-namespace.yaml        namespace monitoring (Pod Security: restricted)
    vmsingle-values.yaml     values vm/victoria-metrics-single 0.49.0 — хранилище (как в ДЗ №4)
    vmagent-values.yaml      values vm/victoria-metrics-agent 0.50.0 — сбор (как в ДЗ №4)
    vmalert-values.yaml      values vm/victoria-metrics-alert 0.51.0 — правила SLO
    grafana-values.yaml      values grafana-community/grafana 14.1.0 — источник данных, дашборд
    30-prober.yaml           пробер: ConfigMap и Deployment
    rules/slo-rules.yaml     правила vmalert: SLI, SLO, SLA, бюджет ошибок, алерты
    rules/tests/             юнит-тесты правил (vmalert-tool unittest)
    dashboards/              дашборд Grafana (JSON)
    rendered/                (в архиве) итоговые манифесты чартов — helm template с теми же values
prober/                      (в архиве) исходники пробера (Python, httpx, prometheus_client) с Dockerfile и тестами
scripts/
  lib.sh                     общие переменные: namespace'ы, версии чартов, образы, порты
  build-image.sh             сборка образов taskflow:2.0 и taskflow-prober:2.0 в minikube
  deploy.sh                  всё: VictoriaMetrics, vmagent, vmalert, Grafana, приложение, пробер
  port-forward.sh            туннели: VictoriaMetrics :8428, vmagent :8429, vmalert :8880, Grafana :3000
  grafana-password.sh        пароль администратора Grafana (из Secret)
  test-rules.sh              юнит-тесты правил SLO в docker (кластер не нужен)
  check-slo.sh               текущие SLI, SLO, SLA и алерты из VictoriaMetrics
  fault.sh                   внести или снять сбой: errors, latency, db-down, db-up, off
  scenario.sh                сценарий сбоев для скринкаста (~45 минут)
  demo.sh                    терминальные части скринкаста (до и после сценария)
  record-screencast.sh       запись скринкаста: терминал (asciinema) + дашборд (кадры Chrome)
  capture-dashboard.mjs      покадровая запись дашборда Grafana с подписью этапа
  replay-dashboard.mjs       кадры дашборда по журналу сценария из истории VictoriaMetrics (--replay)
  screenshot-grafana.sh/.mjs скриншот дашборда или панели Grafana
  grafana-browser.mjs        общее для двух скриптов выше: Chrome и вход в Grafana
  package.json               зависимость *.mjs — playwright-core (версия закреплена в package-lock.json)
  screenshot-vmui.sh         скриншот vmui с MetricsQL-запросом
  screenshot-url.sh          скриншот страницы headless-Chrome'ом
  destroy.sh                 удаление мониторинга (helm uninstall + namespace)
  make-archive.sh            архив для сдачи
screenshots/                 скриншоты для отчёта
screencast/                  скринкаст screencast.mp4, записи терминала (*.cast), журнал сценария
app/                         (в архиве) исходники приложения с Dockerfile
```

Исходники приложения (Python) — в соседнем каталоге `../app`, пробера — в `../prober` (одна кодовая
база для всех заданий). Для этого задания важны `taskflow/faults.py` (внесение сбоев), метрики
`taskflow_fault_injection_*` и тесты; скрипты сами находят `app/Dockerfile` и `prober/Dockerfile` в
распакованном архиве (переопределить — переменными `APP_DIR` и `PROBER_DIR`).

## Быстрый старт

Нужны minikube, kubectl, helm (v3 или v4), docker, curl, jq, python3; для скриншотов и скринкаста —
ещё node, Google Chrome, asciinema 3, agg и ffmpeg (playwright-core скрипты ставят сами в
`scripts/node_modules` из `scripts/package.json`).

```bash
minikube start --driver=docker --container-runtime=docker

scripts/build-image.sh            # taskflow:2.0 и taskflow-prober:2.0 внутри minikube
scripts/deploy.sh                 # мониторинг (Helm), приложение, пробер
scripts/test-rules.sh             # юнит-тесты правил SLO (можно и без кластера)

scripts/port-forward.sh           # в отдельном терминале
scripts/grafana-password.sh       # пароль пользователя admin
scripts/check-slo.sh              # SLI, SLO, SLA, алерты; раздел — аргументом: sli|slo|sla|alerts
```

UI: Grafana — <http://127.0.0.1:3000/d/taskflow-slo>, vmalert — <http://127.0.0.1:8880/vmalert/groups>,
vmui — <http://127.0.0.1:8428/vmui/>.

## Сбои и скринкаст

```bash
scripts/fault.sh errors 0.1       # 10 % запросов к БД падают → ответы 5xx
scripts/fault.sh latency 300      # +300 мс на каждый запрос к БД → медленные ответы
scripts/fault.sh off              # снять сбои приложения
scripts/fault.sh db-down          # остановить PostgreSQL; вернуть — db-up
scripts/fault.sh status           # что сейчас внесено
```

Скринкаст (`scripts/record-screencast.sh`, около 50 минут; с `--short` — около 20) запускает
`scripts/scenario.sh` — все сбои по очереди — и снимает дашборд. Перед записью стоит дать системе
поработать без сбоев хотя бы час: SLO по запросам считаются от всех запросов в окне, и без истории
первый же сбой съест весь бюджет (Отчёт.md, раздел 10). `scripts/record-screencast.sh --replay`
пересобирает видео из прошлой записи, ничего не внося: терминал — из `screencast/*.cast`, дашборд —
по `screencast/scenario.log` из истории VictoriaMetrics.

## Удаление

```bash
scripts/destroy.sh                 # пробер, Grafana, vmalert, vmagent, VictoriaMetrics, namespace monitoring
kubectl delete -f k8s/app/         # приложение и база (как в ДЗ №2)
```
