#!/usr/bin/env bash
# Собирает две версии приложения docker-демоном внутри minikube:
#   taskflow:2.1.0 — текущая (её выкатываем первой),
#   taskflow:2.2.0 — новая (её выкатываем стратегиями ДЗ №8).
# Исходник один; версия задаётся аргументом сборки APP_VERSION и видна в
# /api/version, заголовке X-App-Version, логах и метрике taskflow_build_info.
# Образ собран в minikube — kubelet видит его сразу (imagePullPolicy: Never).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ ! -f "$APP_DIR/Dockerfile" ]]; then
  echo "Dockerfile не найден в $APP_DIR (задайте APP_DIR=путь/к/исходникам)" >&2
  exit 1
fi

# Отдельным присваиванием: если minikube не запущен, set -e остановит скрипт,
# а не соберёт образ молча на демоне хоста.
docker_env="$(minikube docker-env --shell bash)"
eval "$docker_env"

for version in "$V1" "$V2"; do
  docker build --build-arg "APP_VERSION=$version" -t "$IMAGE:$version" "$APP_DIR"
done

echo
echo "Образы в minikube:"
docker image ls "$IMAGE" --format '{{.Repository}}:{{.Tag}}  {{.ID}}  {{.CreatedSince}}'
for version in "$V1" "$V2"; do
  printf '%s:%s → APP_VERSION=' "$IMAGE" "$version"
  docker image inspect "$IMAGE:$version" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^APP_VERSION=//p'
done
