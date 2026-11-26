# Общие переменные и функции скриптов ДЗ №8. Подключается через `source`.
# shellcheck disable=SC2034  # переменные используются в скриптах, которые подключают этот файл
#
# Исходники приложения: в распакованном архиве они лежат в ./app,
# в репозитории — в ../app (одна кодовая база для всех ДЗ).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=taskflow-deploy
EG_NS=envoy-gateway-system
EG_VERSION="${EG_VERSION:-v1.9.4}"

# Две версии приложения из одного исходника — различаются только версией
# сборки (APP_VERSION). Старая — та, что работает, новая — та, что выкатываем.
IMAGE=taskflow
V1=2.1.0
V2=2.2.0

# Шлюз снаружи кластера: kubectl port-forward до Service Envoy (как в quickstart
# Envoy Gateway). Все маршруты привязаны к имени taskflow.local — его передаём
# в заголовке Host.
GW_PORT="${GW_PORT:-8888}"
GW_URL="http://127.0.0.1:${GW_PORT}"
GW_HOST=taskflow.local

if [[ -z "${APP_DIR:-}" ]]; then
  if [[ -f "$ROOT/app/Dockerfile" ]]; then
    APP_DIR="$ROOT/app"
  else
    APP_DIR="$ROOT/../app"
  fi
fi

# Service, который Envoy Gateway создал для прокси нашего Gateway `eg`.
envoy_service() {
  kubectl -n "$EG_NS" get svc \
    -l "gateway.envoyproxy.io/owning-gateway-namespace=$NS,gateway.envoyproxy.io/owning-gateway-name=eg" \
    -o jsonpath='{.items[0].metadata.name}'
}

envoy_selector="gateway.envoyproxy.io/owning-gateway-namespace=$NS,gateway.envoyproxy.io/owning-gateway-name=eg"

# Туннель слушает порт — проверяем TCP, без HTTP-запроса: проверка не должна
# попадать в access-лог Envoy и в статистику демонстраций.
gateway_reachable() {
  (exec 3<>"/dev/tcp/127.0.0.1/$GW_PORT") 2>/dev/null
}

# Поднимает туннель до шлюза, если он ещё не поднят. Туннель, запущенный здесь,
# закрывается при выходе из скрипта (stop_gateway_tunnel в trap).
TUNNEL_PID=""
ensure_gateway_tunnel() {
  if gateway_reachable; then
    return 0
  fi
  local svc
  svc="$(envoy_service)"
  if [[ -z "$svc" ]]; then
    echo "Service прокси Envoy не найден — сначала scripts/deploy-platform.sh" >&2
    return 1
  fi
  kubectl -n "$EG_NS" port-forward "svc/$svc" "$GW_PORT:80" >/dev/null 2>&1 &
  TUNNEL_PID=$!
  for _ in $(seq 1 30); do
    gateway_reachable && return 0
    sleep 0.5
  done
  echo "Туннель до шлюза на $GW_URL не поднялся" >&2
  return 1
}

stop_gateway_tunnel() {
  if [[ -n "$TUNNEL_PID" ]]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
  fi
}

# Удаляет объекты всех стратегий, кроме указанной (метка strategy ставится
# kustomize в каждом k8s/strategies/*). PostgreSQL и Gateway не трогаются.
cleanup_other_strategies() {
  local keep="${1:-}"
  local selector=strategy
  [[ -n "$keep" ]] && selector="strategy,strategy!=$keep"
  kubectl -n "$NS" delete httproute,deployment,service -l "$selector" --ignore-not-found --wait=true
}

traffic() {
  python3 -I "$ROOT/scripts/traffic.py" --url "$GW_URL" --host "$GW_HOST" --versions "$V1,$V2" "$@"
}

# --- Оформление демонстраций (их записывает scripts/record.sh) ----------------
BOLD=$'\e[1m'; DIM=$'\e[2m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
TYPE_DELAY="${TYPE_DELAY:-0.015}"
PAUSE="${PAUSE:-1.2}"

say() { printf '\n%s# %s%s\n' "$BOLD$CYAN" "$1" "$RESET"; sleep 0.6; }
clear_screen() { printf '\e[H\e[2J\e[3J'; }
note() { printf '%s  %s%s\n' "$DIM" "$1" "$RESET"; }

# Команда «печатается» посимвольно и выполняется по-настоящему.
run() {
  local cmd="$1" i
  printf '%s$ %s' "$GREEN" "$RESET"
  for ((i = 0; i < ${#cmd}; i++)); do
    printf '%s' "${cmd:i:1}"
    sleep "$TYPE_DELAY"
  done
  printf '\n'
  bash -o pipefail -c "$cmd" || true
  sleep "$PAUSE"
}

# То же без посимвольной печати: пока в фоне идёт живой трафик, его строки
# не должны разрывать набираемую команду.
run_now() {
  printf '%s$ %s%s\n' "$GREEN" "$1" "$RESET"
  bash -o pipefail -c "$1" || true
}

# --- Журналы демонстрации ------------------------------------------------------
# Время начала — для выборки access-лога Envoy за демонстрацию.
mark_start() { DEMO_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

# Логи приложения собираются потоком (kubectl logs -f) с каждого пода стратегии,
# как только его контейнер запустился: при rolling update старые поды удаляются,
# и после выкатки их логи через kubectl уже не получить.
LOG_CAPTURE_DIR=""
LOG_CAPTURE_PID=""
start_log_capture() {
  local selector="$1"
  LOG_CAPTURE_DIR="$(mktemp -d)"
  (
    trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
    while true; do
      kubectl -n "$NS" get pods -l "$selector" -o \
        jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}' \
        2>/dev/null | while read -r pod started; do
          [[ -n "$started" && ! -e "$LOG_CAPTURE_DIR/$pod.log" ]] || continue
          kubectl -n "$NS" logs -f "$pod" -c taskflow --prefix >"$LOG_CAPTURE_DIR/$pod.log" 2>/dev/null &
        done
      sleep 1
    done
  ) &
  LOG_CAPTURE_PID=$!
}

stop_log_capture() {
  local out="$1"
  [[ -n "$LOG_CAPTURE_PID" ]] || return 0
  kill "$LOG_CAPTURE_PID" 2>/dev/null || true
  wait "$LOG_CAPTURE_PID" 2>/dev/null || true
  pkill -f "kubectl -n $NS logs -f .* -c taskflow --prefix" 2>/dev/null || true
  # Строки всех подов — в одном файле, по времени события.
  cat "$LOG_CAPTURE_DIR"/*.log 2>/dev/null | python3 -I -c '
import json, sys
lines = []
for line in sys.stdin:
    prefix, _, body = line.partition(" ")
    try:
        ts = json.loads(body).get("timestamp", "")
    except ValueError:
        ts = ""
    lines.append((ts, line))
sys.stdout.writelines(line for _, line in sorted(lines, key=lambda x: x[0]))
' >"$out"
  rm -rf "$LOG_CAPTURE_DIR"
  LOG_CAPTURE_PID=""
}

# Сохраняет в logs/ access-лог Envoy и логи приложения за время демонстрации.
save_logs() {
  local name="$1"
  mkdir -p "$ROOT/logs"
  kubectl -n "$EG_NS" logs -l "$envoy_selector" -c envoy --since-time="$DEMO_START" --tail=-1 \
    | grep '^{' >"$ROOT/logs/$name.envoy.log" || true
  stop_log_capture "$ROOT/logs/$name.app.log"
}

# Envoy сбрасывает файловый access-лог раз в 10 с (--file-flush-interval-msec):
# перед чтением журнала ждём, чтобы в выборку попали последние запросы.
wait_envoy_flush() {
  note "ждём сброса access-лога Envoy (раз в 10 с)…"
  sleep 11
}

# Access-лог Envoy за демонстрацию (только JSON-строки запросов).
envoy_log() {
  kubectl -n "$EG_NS" logs -l "$envoy_selector" -c envoy --since-time="$DEMO_START" --tail=-1 | grep '^{'
}

# Ждёт, пока все Deployment стратегии выкатятся.
wait_rollouts() {
  local d
  for d in "$@"; do
    kubectl -n "$NS" rollout status "deployment/$d" --timeout=300s
  done
}

# Чистый старт стратегии: удаляет её объекты и объекты остальных стратегий,
# чтобы демонстрация начиналась с текущей версии 2.1.0.
fresh_strategy() {
  local name="$1"
  cleanup_other_strategies >/dev/null 2>&1 || true
  kubectl -n "$NS" wait --for=delete pod -l strategy --timeout=120s >/dev/null 2>&1 || true
}

PODS_COLUMNS='custom-columns=POD:.metadata.name,TRACK:.metadata.labels.track,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready,STATUS:.status.phase'
PODS_COLUMNS_NO_TRACK='custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready,STATUS:.status.phase'
# Команда выборки access-лога Envoy за демонстрацию — так, как она видна в записи.
envoy_log_cmd() {
  printf 'kubectl -n %s logs -l %s -c envoy --tail=-1 --since-time=%s | grep "^{"' "$EG_NS" "$envoy_selector" "$DEMO_START"
}
ROUTE_COLUMNS='custom-columns=ROUTE:.metadata.name,HOSTNAMES:.spec.hostnames,BACKENDS:.spec.rules[*].backendRefs[*].name,WEIGHTS:.spec.rules[*].backendRefs[*].weight'
