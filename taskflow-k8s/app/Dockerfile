# V. Сборка, релиз, выполнение: образ — это стадия сборки; конфигурация
# (DATABASE_URL, PORT и т. д.) подаётся при запуске, а не вшивается в образ.
FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json ./
# NODE_ENV задаётся только на время установки, а не запекается в образ;
# --ignore-scripts: lifecycle-скрипты зависимостей не выполняются от root.
RUN NODE_ENV=production npm ci --omit=dev --ignore-scripts

COPY src ./src
COPY migrations ./migrations
COPY public ./public

USER node

# Внутри контейнера слушаем все интерфейсы — наружу порт публикует Docker.
ENV HOST=0.0.0.0

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
  CMD node -e "fetch(\`http://127.0.0.1:\${process.env.PORT ?? 3000}/api/ready\`).then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "src/server.js"]
