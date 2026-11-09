// Часть скринкаста ДЗ №2 с интерфейсом: несколько кликов в UI TaskFlow,
// запущенном в minikube (через kubectl port-forward). Playwright записывает
// видео окна браузера (headless Chrome), scripts/record-screencast.sh склеивает
// его с терминальной частью.
//
// Использование: node scripts/ui-demo.mjs URL КАТАЛОГ_ДЛЯ_ВИДЕО
import { chromium } from 'playwright-core';

const [url, videoDir] = process.argv.slice(2);
if (!url || !videoDir) {
  console.error('Использование: node scripts/ui-demo.mjs URL КАТАЛОГ_ДЛЯ_ВИДЕО');
  process.exit(2);
}

const size = { width: 1280, height: 800 };
const browser = await chromium.launch({ channel: 'chrome', headless: true, slowMo: 120 });
const context = await browser.newContext({ viewport: size, recordVideo: { dir: videoDir, size } });
const page = await context.newPage();
page.on('dialog', (dialog) => dialog.accept()); // подтверждение удаления
const pause = (ms = 900) => page.waitForTimeout(ms);

async function newProject(name, description) {
  await page.click('#new-project-btn');
  await pause(400);
  await page.locator('#project-name').pressSequentially(name, { delay: 60 });
  await page.locator('#project-description').pressSequentially(description, { delay: 30 });
  await page.click('#project-form button[type="submit"]');
  await pause();
}

async function newTask(title, status) {
  await page.click('#new-task-btn');
  await pause(400);
  await page.locator('#task-title').pressSequentially(title, { delay: 50 });
  if (status) await page.selectOption('#task-status', status);
  await page.click('#task-form button[type="submit"]');
  await pause();
}

try {
  await page.goto(url, { waitUntil: 'networkidle' });
  await pause(1500);

  await newProject('Диплом', 'ВКР: сдать к маю');
  await newTask('Написать введение');
  await newTask('Собрать данные', 'in_progress');
  await newTask('Сделать графики');

  // Задача «Написать введение» готова — статус меняется прямо в списке.
  await page.selectOption('select[aria-label="Статус задачи «Написать введение»"]', 'done');
  await pause(1200);

  // Фильтры по статусу.
  await page.click('#status-filter >> text=Готово');
  await pause(1200);
  await page.click('#status-filter >> text=В работе');
  await pause(1200);
  await page.click('#status-filter >> text=Все');
  await pause(1000);

  // Удаление задачи.
  await page.locator('li.task-card', { hasText: 'Сделать графики' }).locator('[data-control="delete"]').click();
  await pause(1200);

  // Второй проект и переключение между проектами.
  await newProject('Ремонт', 'Кухня');
  await newTask('Купить краску');
  await page.locator('#project-list >> text=Диплом').click();
  await pause(1800);
} finally {
  await context.close(); // видео дописывается при закрытии контекста
  await browser.close();
}
console.log(await page.video().path());
