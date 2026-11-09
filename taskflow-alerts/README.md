# TaskFlow: алерты (minikube)

Домашнее задание №6. Поверх стека ДЗ №5 (VictoriaMetrics, vmagent, vmalert с правилами SLO, Grafana,
пробер) добавлены алерты на метрики сервиса и рантайма Python и доставка уведомлений:
vmalert → **Alertmanager** → почта дежурного (**Mailpit** — тестовый SMTP-сервер с веб-интерфейсом).
Приложение — TaskFlow 2.0 на Python (FastAPI), исходники в [../app](../app), пробер — в [../prober](../prober).
Описание алертов, условий и демонстрация — в [Отчёт.md](Отчёт.md).

## Состав

```
k8s/
  app/                       манифесты приложения и БД (ДЗ №4–5), образ taskflow:2.0
  monitoring/
    00-namespace.yaml        namespace monitoring (Pod Security: restricted)
    vmsingle-values.yaml     Helm values VictoriaMetrics single
    vmagent-values.yaml      Helm values vmagent (service discovery по аннотациям prometheus.io/*)
    vmalert-values.yaml      Helm values vmalert: правила + notifier.url → Alertmanager   ← ДЗ №6
    grafana-values.yaml      Helm values Grafana, dashboards/ — дашборд SLI/SLO/SLA
    30-prober.yaml           пробер TaskFlow (синтетические сценарии пользователя)
    40-alertmanager.yaml     Alertmanager: маршрутизация, получатели, подавление, шаблон темы  ← ДЗ №6
    41-mailpit.yaml          Mailpit: SMTP :1025 + веб-интерфейс :8025                         ← ДЗ №6
    rules/
      slo-rules.yaml         правила и алерты SLO (ДЗ №5)
      alerts.yaml            алерты сервиса и рантайма Python                                  ← ДЗ №6
      tests/                 юнит-тесты правил (vmalert-tool), alerts.test.yaml — ДЗ №6
scripts/
  build-image.sh             сборка образов taskflow:2.0 и taskflow-prober:2.0 в minikube
  deploy.sh                  весь стек: Helm-чарты, Mailpit, Alertmanager, правила, приложение, пробер
  port-forward.sh            туннели: VictoriaMetrics, vmagent, vmalert, Grafana, Alertmanager, Mailpit
  fault.sh                   сбои: errors, latency, memory, restart, db-down/db-up, off
  alert-demo.sh              демонстрация: fire (вызвать алерты) / recover (снять) / status
  test-rules.sh              юнит-тесты правил (без кластера)
  check-slo.sh               текущие SLI, SLO, SLA и алерты
  screenshot-page.mjs        скриншоты UI (playwright-core + установленный Chrome)
  destroy.sh, make-archive.sh
screenshots/                 скриншоты для отчёта и журнал демонстрации demo-fire.log
```

## Быстрый старт

Нужны minikube, kubectl, helm, curl, python3; для скриншотов — Node.js и Google Chrome.

```bash
minikube start --driver=docker --container-runtime=docker

scripts/build-image.sh            # taskflow:2.0 и taskflow-prober:2.0 внутри minikube
scripts/deploy.sh                 # весь стек (~5 минут)
scripts/test-rules.sh             # юнит-тесты правил: SLO, SLA и алертов ДЗ №6

scripts/port-forward.sh           # в отдельном терминале, держать открытым
scripts/alert-demo.sh fire        # 20 % ошибок + «утечка» памяти + перезапуск процесса → алерты (~6 мин)
open http://127.0.0.1:8880/vmalert/alerts   # vmalert: горящие алерты
open http://127.0.0.1:9093/                 # Alertmanager
open http://127.0.0.1:8025/                 # Mailpit: письма дежурному
scripts/alert-demo.sh recover     # снять сбои, дождаться писем RESOLVED (~15 мин — окно алерта перезапуска)
```

Отдельные сбои: `scripts/fault.sh errors 0.2`, `scripts/fault.sh latency 400`, `scripts/fault.sh memory 160`,
`scripts/fault.sh restart`, `scripts/fault.sh db-down` / `db-up`, `scripts/fault.sh off`.

Скриншоты (нужен `npm ci --prefix scripts`):

```bash
node scripts/screenshot-page.mjs screenshots/x.png "http://127.0.0.1:8880/vmalert/alerts" --click "Expand All" --full
```
