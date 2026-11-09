// Скриншот веб-интерфейса (vmalert, Alertmanager, Mailpit) headless-Chrome'ом
// через playwright-core: в отличие от `chrome --screenshot` умеет нажать кнопку
// («Expand All» в vmalert), ввести текст в фильтр и снять страницу целиком.
//
// Использование:
//   node scripts/screenshot-page.mjs ФАЙЛ.png URL [--click ТЕКСТ]… [--fill СЕЛЕКТОР=ТЕКСТ]…
//                                    [--height N] [--full] [--wait МС]
// Нужен установленный Google Chrome и npm ci --prefix scripts.
import { chromium } from 'playwright-core';

const [out, url, ...rest] = process.argv.slice(2);
if (!out || !url) {
  console.error('Использование: node scripts/screenshot-page.mjs ФАЙЛ.png URL [--click ТЕКСТ] [--fill СЕЛЕКТОР=ТЕКСТ] [--height N] [--full] [--wait МС]');
  process.exit(2);
}

const actions = [];
let height = 900;
let fullPage = false;
let waitMs = 800;
for (let i = 0; i < rest.length; i += 1) {
  const arg = rest[i];
  if (arg === '--click') actions.push({ click: rest[++i] });
  else if (arg === '--fill') {
    const [selector, ...value] = rest[++i].split('=');
    actions.push({ fill: selector, value: value.join('=') });
  } else if (arg === '--height') height = Number.parseInt(rest[++i], 10);
  else if (arg === '--full') fullPage = true;
  else if (arg === '--wait') waitMs = Number.parseInt(rest[++i], 10);
  else {
    console.error(`Неизвестный аргумент: ${arg}`);
    process.exit(2);
  }
}

const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1440, height } });
  await page.goto(url, { waitUntil: 'networkidle' });
  for (const action of actions) {
    if (action.click) await page.getByText(action.click, { exact: true }).first().click();
    if (action.fill) await page.locator(action.fill).first().fill(action.value);
    await page.waitForTimeout(300);
  }
  await page.waitForTimeout(waitMs);
  await page.screenshot({ path: out, fullPage });
  console.log(`Скриншот: ${out}`);
} finally {
  await browser.close();
}
