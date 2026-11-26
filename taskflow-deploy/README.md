# TaskFlow: стратегии выкатки через Envoy Gateway

ДЗ №8. Приложение TaskFlow работает в нескольких подах за **Envoy Gateway** (реализация Gateway
API) в minikube. Новая версия выкатывается пятью стратегиями: **Rolling**, **Blue/Green**,
**Canary**, **A/B** и **Shadow**.

Материалы для сдачи:

- [Отчёт.md](Отчёт.md) — что изменено в приложении, устройство стенда, каждая стратегия с
  результатами и выводами.
- `screencast/N-<стратегия>.mp4` — видео каждой стратегии (терминал, команды и вывод настоящие);
  `screencast/all-strategies.mp4` — все пять подряд.
- `logs/N-<стратегия>.terminal.log` — текст всего, что было на экране;
  `logs/N-<стратегия>.envoy.log` — access-лог Envoy за демонстрацию (какая версия ответила на каждый
  запрос); `logs/N-<стратегия>.app.log` — логи всех подов приложения за демонстрацию.

| № | Стратегия | Видео | Сценарий |
|---|---|---|---|
| 1 | Rolling — постепенная замена реплик | [1-rolling.mp4](screencast/1-rolling.mp4) | [demo-rolling.sh](scripts/demo-rolling.sh) |
| 2 | Blue/Green — мгновенное переключение и откат | [2-blue-green.mp4](screencast/2-blue-green.mp4) | [demo-blue-green.sh](scripts/demo-blue-green.sh) |
| 3 | Canary — 90/10 → 50/50 → 0/100 | [3-canary.mp4](screencast/3-canary.mp4) | [demo-canary.sh](scripts/demo-canary.sh) |
| 4 | A/B — по заголовку `X-User-Group: beta` | [4-ab-testing.mp4](screencast/4-ab-testing.mp4) | [demo-ab.sh](scripts/demo-ab.sh) |
| 5 | Shadow — зеркалирование копии трафика | [5-shadow.mp4](screencast/5-shadow.mp4) | [demo-shadow.sh](scripts/demo-shadow.sh) |

## Состав

```
k8s/
  platform/     namespace taskflow-deploy, ConfigMap, Secret, PostgreSQL (состояние вне подов)
  gateway/      GatewayClass eg, EnvoyProxy (access-лог, Service ClusterIP), Gateway eg,
                BackendTrafficPolicy (таймаут простоя соединений к подам)
  app/          база kustomize: Deployment + Service taskflow (образ taskflow:2.1.0)
  strategies/   по каталогу на стратегию: kustomization + HTTPRoute
scripts/
  install-envoy-gateway.sh   Envoy Gateway v1.9.4 (CRD Gateway API + контроллер)
  build-images.sh            образы taskflow:2.1.0 и taskflow:2.2.0 в minikube
  deploy-platform.sh         namespace, PostgreSQL, Gateway
  demo-*.sh                  сценарии демонстраций (их записывает record.sh)
  record.sh                  запись видео и логов
  traffic.sh, traffic.py     трафик через шлюз с разбором ответов по версиям
  make-archive.sh, destroy.sh
```

## Запуск с нуля

Нужны minikube (проверено на v1.39, Kubernetes v1.37, драйвер docker), kubectl, jq, python3.
Для записи видео — asciinema 3, agg и ffmpeg (`brew install asciinema agg ffmpeg jq`).

Стенду вместе с мониторингом прошлых ДЗ нужно около 5 ГБ памяти и запас CPU. При 2 CPU и 4 ГБ
узел упирался в память, PostgreSQL перезапускался по liveness, а при рендере видео троттлинг CPU
доводил узел до NotReady. Новый кластер: `minikube start --cpus 8 --memory 6g`. У существующего на
драйвере docker лимиты можно поднять на лету:
`docker update --cpus 8 --memory 6g --memory-swap 6g minikube`.

```bash
cd taskflow-deploy
scripts/install-envoy-gateway.sh   # Envoy Gateway v1.9.4
scripts/build-images.sh            # taskflow:2.1.0 и taskflow:2.2.0
scripts/deploy-platform.sh         # namespace, PostgreSQL, GatewayClass/Gateway eg
```

Любая стратегия разворачивается сценарием и сама удаляет объекты предыдущей. Сценарий поднимает
туннель до Envoy (`kubectl port-forward` на `127.0.0.1:8888`, как в quickstart Envoy Gateway):

```bash
bash scripts/demo-canary.sh        # или demo-rolling / demo-blue-green / demo-ab / demo-shadow
```

Вручную — те же объекты через kustomize:

```bash
kubectl apply -k k8s/strategies/canary
kubectl -n envoy-gateway-system port-forward \
  "svc/$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=eg -o jsonpath='{.items[0].metadata.name}')" 8888:80 &
curl -H 'Host: taskflow.local' http://127.0.0.1:8888/api/version
scripts/traffic.sh --duration 10              # распределение ответов по версиям
```

## Перезаписать видео и логи

```bash
scripts/record.sh                  # все пять; или выборочно: scripts/record.sh canary shadow
scripts/make-archive.sh            # ../taskflow-deploy.zip
```

Запись идёт около 10 минут, рендер видео после неё — ещё около 20 (с пониженным приоритетом, чтобы не мешать кластеру); `RENDER_ONLY=1 scripts/record.sh` перерендерит видео из готовых `.cast` без новой записи. Паузы длиннее 2 с в видео сжимаются (`--idle-time-limit 2`), поэтому
время в живых строках трафика может «перескакивать».

## Удалить

```bash
scripts/destroy.sh                      # namespace taskflow-deploy и GatewayClass eg
scripts/destroy.sh --uninstall-gateway  # и сам Envoy Gateway
```

Стенд прошлых ДЗ (namespace `taskflow`, `monitoring`, `logging`) эти скрипты не трогают.
