// Real browser recording of the running Grafana dashboards, without credentials on screen.
import { chromium } from 'playwright-core';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const origin = process.env.GRAFANA_URL || 'http://127.0.0.1:3000';
const screenshots = path.join(root, 'screenshots');
const videos = path.join(root, 'screencast');
await mkdir(screenshots, { recursive: true });
await mkdir(videos, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const context = await browser.newContext({
  viewport: { width: 1920, height: 1080 }, locale: 'ru-RU', timezoneId: 'Europe/Moscow',
  colorScheme: 'light', recordVideo: { dir: videos, size: { width: 1920, height: 1080 } },
});
const errors = [];
const stages = [];
const start = Date.now();
let page;
let video;
let completed = false;

async function caption(text) {
  await page.evaluate((text) => {
    let node = document.getElementById('homework-caption');
    if (!node) {
      node = document.createElement('div');
      node.id = 'homework-caption';
      Object.assign(node.style, {
        position: 'fixed', bottom: '0', left: '0', right: '0', zIndex: '100000',
        background: 'rgba(15,23,42,.94)', color: '#f1f5f9', padding: '12px 24px',
        font: '500 18px/1.4 system-ui, sans-serif', pointerEvents: 'none',
      });
      document.body.append(node);
    }
    node.textContent = text;
  }, text);
}

async function load(route) {
  const response = await page.goto(origin + route, { waitUntil: 'load', timeout: 60000 });
  if (!response?.ok() || page.url().includes('/login')) throw new Error(`Не открыт ${route}`);
  await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});
  await page.waitForTimeout(2500);
}

async function section(title) {
  const header = page.getByText(title, { exact: true }).first();
  await header.scrollIntoViewIfNeeded({ timeout: 30000 });
  // Align the selected row with the top of the scrolling dashboard, keeping Grafana's toolbar.
  await header.evaluate((node) => node.scrollIntoView({ behavior: 'instant', block: 'start' }));
  await page.waitForTimeout(2500);
}

async function save(name, label, pauseMs = 6500) {
  stages.push({ at_seconds: Math.round((Date.now() - start) / 1000), screenshot: name, description: label, url: page.url() });
  await caption(label);
  await page.screenshot({ path: path.join(screenshots, name) });
  console.log(`Снято: ${name}`);
  await page.waitForTimeout(pauseMs);
}

try {
  const login = await context.request.post(origin + '/login', {
    data: { user: process.env.GRAFANA_USER, password: process.env.GRAFANA_PASSWORD },
  });
  if (!login.ok()) throw new Error(`Вход в Grafana: ${login.status()}`);
  page = await context.newPage();
  video = page.video();
  page.on('response', (response) => {
    if (response.url().includes('/api/ds/query') && response.status() >= 400) errors.push({ status: response.status(), url: response.url() });
  });
  await load('/connections/datasources/edit/victoriametrics');
  await save('06-victoriametrics-datasource.png', '01 / Источник данных: VictoriaMetrics через встроенный Prometheus datasource.');

  await load('/d/taskflow-overview?from=now-1h&to=now');
  await page.waitForSelector('.react-grid-item');
  await save('01-application-red.png', '02 / TaskFlow: доступность реплик и БД, RPS, ошибки и задержка API — подход RED.');

  await section('02 · Рантайм Python / ресурсы процесса');
  await save('02-python-runtime.png', '03 / Python: CPU, RSS, файловые дескрипторы, сборщик мусора и время работы процессов.');

  await section('03 · SLA и внешний взгляд пробера');
  await save('03-prober-sla.png', '04 / Отдельная панель SLA пробера за 30d; рядом цель 99%, SLA сервиса и покрытие окна.');

  await section('04 · Метрики продукта / результат пользовательских действий');
  await save('07-business-metrics.png', '05 / Метрики продукта: создание задач, переходы статусов и время до завершения.', 4500);

  await load('/d/taskflow-postgresql?from=now-1h&to=now');
  await save('04-postgresql-overview.png', '06 / Импорт PostgreSQL Database, Grafana.com 9628/r8: доступность БД, экспортер и настройки.');

  await section('03 · Работа базы данных / postgres-exporter');
  await save('05-postgresql-database.png', '07 / Живые данные PostgreSQL: сессии, транзакции, операции с данными и блокировки.');

  await page.getByText('Cache Hit Rate', { exact: true }).first().scrollIntoViewIfNeeded();
  await save('08-postgresql-io.png', '08 / PostgreSQL: cache hit ratio, bgwriter, конфликты, deadlocks, временные файлы и I/O.', 4500);
  completed = true;
} finally {
  await context.close();
  await browser.close();
}
if (!completed) throw new Error('Запись не завершена');
if (errors.length) throw new Error(`Ошибки запросов Grafana: ${JSON.stringify(errors)}`);
const recorded = await video.path();
const result = spawnSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', recorded,
  '-c:v', 'libx264', '-preset', 'fast', '-crf', '24', '-pix_fmt', 'yuv420p',
  '-movflags', '+faststart', path.join(videos, 'screencast.mp4')], { stdio: 'inherit' });
if (result.status !== 0) throw new Error('ffmpeg не создал MP4');
await writeFile(path.join(videos, 'chapters.json'), JSON.stringify({ recorded_at: new Date().toISOString(), stages, query_errors: errors }, null, 2) + '\n');
console.log('Готово: screencast/screencast.mp4');
