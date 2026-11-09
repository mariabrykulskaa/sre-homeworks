# V. Сборка, релиз, выполнение: образ — это стадия сборки; конфигурация
# (DATABASE_URL, PORT и т. д.) подаётся при запуске, а не вшивается в образ.
FROM python:3.13-slim

# Не писать .pyc (файловая система контейнера — только для чтения) и не
# буферизовать stdout: каждая строка лога уходит сразу.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Сначала только зависимости: пока requirements.txt не меняется, этот слой
# берётся из кэша и пересборка после правки кода занимает секунды.
COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY taskflow ./taskflow
COPY migrations ./migrations
COPY public ./public

# Запуск не от root: uid 1000 — тот же, что требуют манифесты Kubernetes.
RUN useradd --uid 1000 --no-create-home --shell /usr/sbin/nologin app
USER 1000

# Внутри контейнера слушаем все интерфейсы — наружу порт публикует Docker.
ENV HOST=0.0.0.0

# 3000 — приложение, 9464 — /metrics (METRICS_PORT) для системы мониторинга.
EXPOSE 3000 9464

HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
  CMD python -c "import os, urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\", \"3000\")}/api/ready', timeout=2)"

CMD ["python", "-m", "taskflow.server"]
