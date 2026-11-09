# TaskFlow в Kubernetes (minikube)

Домашнее задание №2: развёртывание приложения TaskFlow (Python + FastAPI + PostgreSQL) из первого задания
в однонодовом кластере minikube. Описание абстракций и взаимодействия сервисов — в [Отчёт.md](Отчёт.md).

## Состав

```
k8s/
  00-namespace.yaml   Namespace taskflow (с профилем Pod Security «restricted»)
  01-configmap.yaml   ConfigMap: порт, APP_ENV, имя БД/пользователя, адрес Service БД
  02-secret.yaml      Secret: пароль PostgreSQL
  10-postgres.yaml    Headless Service db + StatefulSet PostgreSQL с PersistentVolumeClaim
  20-app.yaml         Deployment taskflow (init-контейнеры: ожидание БД, миграции) + Service NodePort
scripts/
  build-image.sh      сборка образа демоном minikube (eval $(minikube docker-env))
  load-image.sh       альтернатива: сборка на хосте + minikube image load
  deploy.sh           kubectl apply + ожидание готовности
  destroy.sh          удаление namespace со всем содержимым (включая том БД)
  make-archive.sh     архив для сдачи
  demo.sh             терминальная часть скринкаста (apply, get pods, scale)
  ui-demo.mjs         клики в UI для скринкаста (Playwright + установленный Chrome)
  record-screencast.sh  запись скринкаста: asciinema + Playwright → screencast/screencast.mp4
screencast/           скринкаст (screencast.mp4) и запись терминала terminal.cast
app/                  (в архиве) исходники приложения и его Dockerfile
```

Исходники приложения и Dockerfile живут в соседнем каталоге `../app` — одна кодовая база,
один Dockerfile. Скрипт архивации копирует их в `app/`, и скрипты сборки сами находят
`app/Dockerfile`, если он есть (иначе `../app`; переопределить — переменной `APP_DIR`).

## Быстрый старт

```bash
# 1. Кластер
minikube start --driver=docker --container-runtime=docker

# 2. Образ приложения внутри minikube
scripts/build-image.sh                     # или scripts/load-image.sh

# 3. Развёртывание
scripts/deploy.sh                          # = kubectl apply -f k8s/ + rollout status

# 4. UI
minikube service taskflow -n taskflow      # на macOS NodePort доступен только через этот туннель
```

Сборка руками вместо скрипта:

```bash
eval $(minikube docker-env)                # bash/zsh
minikube docker-env | source               # fish
docker build -t taskflow:2.0 ../app        # или ./app в распакованном архиве
```

## Полезные команды

```bash
kubectl get pods -n taskflow -o wide
kubectl get all,pvc -n taskflow
kubectl scale deployment/taskflow -n taskflow --replicas=4
kubectl logs -n taskflow -l app.kubernetes.io/name=taskflow -c taskflow --prefix -f
kubectl logs -n taskflow deploy/taskflow -c migrate         # лог миграций
kubectl exec -n taskflow db-0 -- psql -U taskflow -c '\dt'  # заглянуть в БД
scripts/destroy.sh                                          # снести всё
```

## Обновление образа

Deployment ссылается на `taskflow:2.0` с `imagePullPolicy: Never`. Чтобы выкатить новую версию,
соберите образ с новым тегом, поменяйте тег в `k8s/20-app.yaml` (в init-контейнере `migrate`
и в основном контейнере) и примените манифест — Kubernetes сделает RollingUpdate:

```bash
scripts/build-image.sh taskflow:2.1
sed -i.bak 's/taskflow:2\.0/taskflow:2.1/g' k8s/20-app.yaml && rm k8s/20-app.yaml.bak
kubectl apply -f k8s/20-app.yaml
kubectl rollout status deployment/taskflow -n taskflow
```

Менять тег через `kubectl set image` не стоит: следующий `kubectl apply -f k8s/` откатит его обратно.
То же касается `kubectl scale`: число реплик в манифесте — 2, и повторный `apply` вернёт его.

## Смена пароля БД

Пароль в `k8s/02-secret.yaml` используется PostgreSQL только при первой инициализации тома.
Если поменять Secret у уже развёрнутой базы, приложение перестанет подключаться: в томе остался
старый пароль. Для dev-стенда проще всего `scripts/destroy.sh` (удалит том) и заново `deploy.sh`.
