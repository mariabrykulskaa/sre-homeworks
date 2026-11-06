// Скриншот страницы UI после клика по кнопке (vmalert и Alertmanager прячут
// подробности за «Expand All» / «Expand all groups», так что простого
// headless-скриншота мало). Использует установленный Google Chrome.
//
//   npx -y -p playwright-core@1.52.0 node scripts/screenshot-ui.mjs ФАЙЛ.png URL ["текст кнопки"] [высота]
//
// Примеры:
//   ... screenshots/06-vmalert-alerts.png http://127.0.0.1:8880/vmalert/alerts "Expand All" 1100
//   ... screenshots/07-alertmanager.png   http://127.0.0.1:9093/            "Expand all groups" 900
import { chromium } from 'playwright-core';

const [out, url, buttonText, height = '900'] = process.argv.slice(2);
if (!out || !url) {
  console.error('Использование: node scripts/screenshot-ui.mjs ФАЙЛ.png URL ["текст кнопки"] [высота]');
  process.exit(2);
}
const viewportHeight = Number.parseInt(height, 10);
if (!Number.isInteger(viewportHeight) || viewportHeight <= 0) {
  console.error(`Высота должна быть положительным числом, получено «${height}»`);
  process.exit(2);
}

const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: viewportHeight } });
  await page.goto(url, { waitUntil: 'networkidle' });
  if (buttonText) {
    await page.getByText(buttonText, { exact: true }).first().click();
    // Даём раскрывшимся блокам отрисоваться.
    await page.waitForTimeout(800);
  }
  await page.screenshot({ path: out });
  console.log(`Скриншот: ${out}`);
} finally {
  await browser.close();
}
