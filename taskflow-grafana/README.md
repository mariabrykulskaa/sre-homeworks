# TaskFlow: дашборды Grafana

Готовые материалы для сдачи:

- [Отчёт.md](Отчёт.md) — выбор панелей и метрик, формулы SLA, скриншоты и результаты проверки.
- [dashboards/taskflow-overview.json](dashboards/taskflow-overview.json) — экспорт дашборда приложения из работающей Grafana.
- [dashboards/postgresql-exporter.json](dashboards/postgresql-exporter.json) — экспорт импортированного дашборда PostgreSQL.
- [screencast/screencast.mp4](screencast/screencast.mp4) — короткая запись реального браузера: источник данных, приложение, Python, SLA и PostgreSQL.

## Открыть работающий стенд

Нужен запущенный minikube со стеком из ДЗ №4–5: приложение TaskFlow, PostgreSQL с postgres-exporter, VictoriaMetrics, vmagent, vmalert с правилами SLO и Grafana. В этом репозитории такой стенд уже развёрнут.

```bash
cd taskflow-grafana
scripts/port-forward.sh
```

Если порты уже заняты работающими туннелями, повторно запускать их не нужно.

В другом терминале:

```bash
scripts/grafana-password.sh  # пользователь admin, пароль из Secret grafana-admin
```

- Приложение: http://127.0.0.1:3000/d/taskflow-overview
- PostgreSQL: http://127.0.0.1:3000/d/taskflow-postgresql
- Исходный дашборд ДЗ №5: http://127.0.0.1:3000/d/taskflow-slo

## Установить дашборды воспроизводимо

```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update grafana-community
bash scripts/deploy.sh
```

Скрипт обновляет ConfigMap с тремя дашбордами и Helm-релиз Grafana. UID источника данных — `victoriametrics`, тип — встроенный `prometheus`. JSON для provisioning лежат в `k8s/monitoring/dashboards/`; источник и параметры Grafana — в `k8s/monitoring/grafana-values.yaml`. При смене пода Grafana туннель `port-forward` нужно запустить заново.

Входные конфигурации приложения, экспортера и сбора метрик сохранены в `k8s/app/` и `k8s/monitoring/`. Этот скрипт не меняет правила алертов и приложение.

Для ручного импорта в другой экземпляр Grafana: добавьте Prometheus datasource с URL VictoriaMetrics и UID `victoriametrics`, затем Dashboards → New → Import → загрузите JSON из `dashboards/`. Экспорт сохраняет этот UID; при другом UID замените ссылки `datasource.uid` перед импортом.

## Проверить и переснять материалы

Из корня репозитория:

```bash
python3 -I taskflow-grafana/scripts/grafana.py verify
python3 -I taskflow-grafana/scripts/grafana.py export
```

Для скриншотов и MP4 нужны Node.js, установленный Google Chrome, ffmpeg и зависимости скриптов:

```bash
npm ci --prefix taskflow-grafana/scripts --ignore-scripts --no-audit --no-fund
python3 -I taskflow-grafana/scripts/grafana.py capture
python3 -I taskflow-grafana/scripts/make-archive.py
```

`grafana.py` берёт пароль через `kubectl` и передаёт его браузеру в окружении. Пароль не записывается в видео или отчёт. `capture` сохраняет MP4, PNG и журнал разделов `screencast/chapters.json`; в видео добавлены поясняющие подписи.

Архив `taskflow-grafana.zip` появляется рядом с каталогом домашки. Он включает исходники приложения и пробера; зависимости и локальные `.env` исключены. После распаковки команды из примеров с префиксом `taskflow-grafana/` выполняются из каталога, содержащего распакованную папку.

## Происхождение PostgreSQL-дашборда

Импортирован [PostgreSQL Database, Grafana.com 9628, revision 8](https://grafana.com/grafana/dashboards/9628-postgresql-database/) автора Lucas Estienne. Неизменённый исходник сохранён в `dashboards/upstream/postgresql-9628-r8.json`. Адаптация для текущего стенда описана в отчёте; генератор — `scripts/build-dashboards.py`. Оригинал скачивать повторно для импорта готового экспорта не требуется.
