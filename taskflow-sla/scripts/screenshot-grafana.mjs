// Скриншот дашборда Grafana (или одной его панели) для отчёта.
//
//   GRAFANA_USER=… GRAFANA_PASSWORD=… \
//   node scripts/screenshot-grafana.mjs ФАЙЛ.png URL [высота]
//
// URL одной панели — /d/taskflow-slo?viewPanel=<id>. Обёртка, которая берёт
// пароль из Secret: scripts/screenshot-grafana.sh.
import { openGrafana } from './grafana-browser.mjs';

const [out, url, heightArg = '1080'] = process.argv.slice(2);
if (!out || !url) {
  console.error('Использование: node scripts/screenshot-grafana.mjs ФАЙЛ.png URL [высота]');
  process.exit(2);
}
const height = Number(heightArg);
if (!Number.isInteger(height) || height <= 0) {
  console.error(`Высота — положительное целое число, получено «${heightArg}»`);
  process.exit(2);
}

const { browser, page } = await openGrafana(url, { height });
try {
  await page.screenshot({ path: out });
} finally {
  await browser.close();
}
console.log(`Скриншот: ${out}`);
