// Покадровая запись дашборда Grafana для скринкаста: раз в INTERVAL секунд —
// дашборд загружается заново и снимается. Внизу кадра — плашка с часами, текущим этапом сценария и
// командой, которой он начат (их пишет scripts/scenario.sh в файл подписи):
// видно, что сделали с приложением и как на это ответили графики.
//
//   GRAFANA_USER=… GRAFANA_PASSWORD=… \
//   node scripts/capture-dashboard.mjs URL КАТАЛОГ ПОДПИСЬ СТОП [интервал]
//
// URL — дашборд; КАТАЛОГ — куда класть кадры frame-00001.png…; ПОДПИСЬ — файл
// из двух строк (этап, команда); СТОП — файл-флаг: когда он появится, запись
// завершается. Запускает scripts/record-screencast.sh.
import { access, mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { drawBanner, openGrafana, showDashboard } from './grafana-browser.mjs';

const [url, framesDir, captionFile, stopFile, intervalArg = '10'] = process.argv.slice(2);
if (!url || !framesDir || !captionFile || !stopFile) {
  console.error('Использование: node scripts/capture-dashboard.mjs URL КАТАЛОГ ПОДПИСЬ СТОП [интервал]');
  process.exit(2);
}
const intervalMs = Number(intervalArg) * 1000;
if (!Number.isInteger(intervalMs) || intervalMs < 1000) {
  console.error(`Интервал — целое число секунд от 1, получено «${intervalArg}»`);
  process.exit(2);
}

const exists = (file) => access(file).then(() => true, () => false);

async function readCaption() {
  const text = await readFile(captionFile, 'utf8').catch((err) => {
    if (err.code === 'ENOENT') return '';
    throw err;
  });
  const [stage = '', command = ''] = text.split('\n');
  return { stage, command };
}

// Сколько неудачных кадров подряд терпим: единичный сбой (Grafana не
// ответила вовремя) — пропуск кадра; долгая серия — запись бесполезна.
const MAX_FAILURES_IN_ROW = 6;

async function captureFrame(page, file) {
  await showDashboard(page, url, { settleMs: 1000 });
  const clock = new Date().toLocaleTimeString('ru-RU', { hour12: false });
  await page.evaluate(drawBanner, { ...(await readCaption()), clock });
  await page.screenshot({ path: file });
}

await mkdir(framesDir, { recursive: true });
const { browser, page } = await openGrafana(url);
let frame = 0;
let failuresInRow = 0;
try {
  while (!(await exists(stopFile))) {
    const startedAt = Date.now();
    const file = path.join(framesDir, `frame-${String(frame + 1).padStart(5, '0')}.png`);
    try {
      await captureFrame(page, file);
      frame += 1;
      failuresInRow = 0;
    } catch (err) {
      failuresInRow += 1;
      console.error(`Кадр не снят (${failuresInRow} подряд): ${err.message}`);
      if (failuresInRow >= MAX_FAILURES_IN_ROW) throw err;
    }
    await sleep(Math.max(0, intervalMs - (Date.now() - startedAt)));
  }
} finally {
  await browser.close();
}
console.log(`Кадров: ${frame} → ${framesDir}`);
