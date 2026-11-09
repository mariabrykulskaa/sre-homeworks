# Образ пробера: та же схема, что у TaskFlow (app/Dockerfile) — зависимости
# отдельным слоем, запуск не от root, без .pyc на диске.
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY prober ./prober

RUN useradd --uid 1000 --no-create-home --shell /usr/sbin/nologin app
USER 1000

# /metrics слушает все интерфейсы контейнера: его забирает vmagent по IP пода.
ENV HOST=0.0.0.0

EXPOSE 9464

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD python -c "import os, urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"METRICS_PORT\", \"9464\")}/metrics', timeout=2)"

CMD ["python", "-m", "prober"]
