// Общее для скриншотов и покадровой записи Grafana: headless Chrome (установленный
// Google Chrome, через playwright-core) с входом по логину и паролю. playwright-core
// ставится в scripts/node_modules из scripts/package.json (ensure_node_deps в lib.sh).
//
// Учётные данные — из переменных GRAFANA_USER и GRAFANA_PASSWORD, а не из
// аргументов: аргументы процесса видны всем в `ps`. Скрипты-обёртки берут
// пароль из Secret grafana-admin (scripts/grafana-password.sh).
import { chromium } from 'playwright-core';

export const VIEWPORT = Object.freeze({ width: 1920, height: 1080 });

export function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`Не задана переменная ${name}`);
    process.exit(2);
  }
  return value;
}

// Открывает дашборд и ждёт, пока панели получат данные. Вход — как у
// человека: POST /login ставит cookie сессии в контекст браузера (basic auth
// в заголовке интерфейс Grafana не держит — фронтенд уводит на /login).
export async function openGrafana(url, { height = VIEWPORT.height } = {}) {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const context = await browser.newContext({
      viewport: { width: VIEWPORT.width, height },
      locale: 'ru-RU',
      colorScheme: 'light',
    });
    await signIn(context, url);
    const page = await context.newPage();
    await showDashboard(page, url);
    return { browser, page };
  } catch (err) {
    await browser.close();
    throw err;
  }
}

// Вход в Grafana: cookie сессии — в контекст браузера. Повторяют после
// перезапуска пода Grafana: без постоянного хранилища сессии теряются.
export async function signIn(context, url) {
  const { origin } = new URL(url);
  const login = await context.request.post(`${origin}/login`, {
    data: { user: requireEnv('GRAFANA_USER'), password: requireEnv('GRAFANA_PASSWORD') },
  });
  if (!login.ok()) {
    throw new Error(`Grafana не приняла логин и пароль (POST /login → ${login.status()})`);
  }
}

// Загружает дашборд заново и ждёт данных панелей. Для покадровой записи —
// на каждый кадр: одна долго открытая вкладка с автообновлением Grafana на
// перегруженной машине застревала на «No data», свежая загрузка — нет.
// settleMs — пауза на отрисовку графиков после того, как стихли запросы.
export async function showDashboard(page, url, { settleMs = 3000 } = {}) {
  const response = await page.goto(url, { waitUntil: 'load' });
  if (!response?.ok()) {
    throw new Error(`Grafana ответила ${response?.status()} на ${url}`);
  }
  if (new URL(page.url()).pathname.startsWith('/login')) {
    throw new Error('Grafana не приняла логин и пароль (редирект на /login)');
  }
  await page.waitForSelector('.react-grid-item', { timeout: 30_000 });
  await page.waitForLoadState('networkidle', { timeout: 30_000 })
    .catch(() => console.warn('Запросы панелей не стихли за 30 с — снимок как есть'));
  await page.waitForTimeout(settleMs);
}

// Плашка внизу кадра скринкаста: часы, этап сценария и команда, которой он
// начат. Выполняется в странице (page.evaluate); текст — через textContent, без HTML.
export function drawBanner({ stage, command, clock }) {
  let banner = document.getElementById('screencast-banner');
  if (!banner) {
    banner = document.createElement('div');
    banner.id = 'screencast-banner';
    Object.assign(banner.style, {
      position: 'fixed', left: '0', right: '0', bottom: '0', zIndex: '100000',
      display: 'flex', gap: '28px', alignItems: 'baseline', padding: '10px 20px',
      background: 'rgba(17, 24, 39, 0.92)', color: '#f9fafb',
      font: '500 20px/1.3 "JetBrains Mono", Menlo, monospace',
    });
    for (let i = 0; i < 3; i += 1) banner.append(document.createElement('span'));
    banner.children[0].style.color = '#9ca3af';
    banner.children[1].style.flex = '1';
    banner.children[2].style.color = '#86efac';
    document.body.append(banner);
  }
  banner.children[0].textContent = clock;
  banner.children[1].textContent = stage;
  banner.children[2].textContent = command ? `$ ${command}` : '';
}
