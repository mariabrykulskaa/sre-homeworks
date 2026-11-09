// Покадровая отрисовка дашборда Grafana по уже записанным метрикам: для
// каждого момента t сценария — дашборд с абсолютным диапазоном [начало; t].
// Мгновенные панели (SLA, бюджет, алерты) считаются на момент t, графики
// «дорастают» до t. Плашка внизу — время t, этап и команда из журнала
// сценария (screencast/scenario.log). Сбои заново не вносятся: данные уже
// лежат в VictoriaMetrics, кадры можно пересобрать, если живая запись не
// удалась, или снять чаще, чем позволяла перегруженная машина.
//
//   GRAFANA_USER=… GRAFANA_PASSWORD=… \
//   node scripts/replay-dashboard.mjs URL ЖУРНАЛ ДАТА КАТАЛОГ [шаг]
//
// URL — дашборд без from/to; ЖУРНАЛ — scenario.log; ДАТА — день сценария
// (ГГГГ-ММ-ДД, время в журнале — местное, сценарий — в пределах суток);
// КАТАЛОГ — куда класть кадры frame-00001.png…; ШАГ — секунд между кадрами.
// Запускает scripts/record-screencast.sh --replay.
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { drawBanner, openGrafana, showDashboard, signIn } from './grafana-browser.mjs';

const [url, logFile, day, framesDir, stepArg = '10'] = process.argv.slice(2);
if (!url || !logFile || !/^\d{4}-\d{2}-\d{2}$/.test(day ?? '') || !framesDir) {
  console.error('Использование: node scripts/replay-dashboard.mjs URL ЖУРНАЛ ГГГГ-ММ-ДД КАТАЛОГ [шаг]');
  process.exit(2);
}
const stepMs = Number(stepArg) * 1000;
if (!Number.isInteger(stepMs) || stepMs < 1000) {
  console.error(`Шаг — целое число секунд от 1, получено «${stepArg}»`);
  process.exit(2);
}
const LEAD_MS = 2 * 60_000;   // диапазон начинается за 2 минуты до сценария
const TAIL_MS = 60_000;       // и идёт минуту после: последние точки приходят с задержкой
// Кадр пропускать нельзя — каждый момент сценария на счету. Если Grafana не
// ответила (на перегруженной машине её под перезапускается, туннель
// переподключается), ждём и повторяем, войдя заново.
const ATTEMPTS = 12;
const RETRY_DELAY_MS = 10_000;

// Этапы из журнала: «[ЧЧ:ММ:СС] == этап (N мин)», следом «$ команда».
function parseStages(text) {
  const stages = [];
  let end = null;
  for (const line of text.split('\n')) {
    const stage = line.match(/^\[(\d{2}:\d{2}:\d{2})\] == (.+?) \(\d+ мин\)$/);
    if (stage) {
      stages.push({ at: new Date(`${day}T${stage[1]}`).getTime(), title: stage[2], command: '' });
      continue;
    }
    const command = line.match(/^\$ (scripts\/fault\.sh .+)$/);
    if (command && stages.length > 0) stages.at(-1).command = command[1];
    const done = line.match(/^\[(\d{2}:\d{2}:\d{2})\] Сценарий завершён/);
    if (done) end = new Date(`${day}T${done[1]}`).getTime();
  }
  if (stages.length === 0 || end === null) throw new Error(`В ${logFile} нет этапов или строки о завершении`);
  return { stages, end };
}

const { stages, end } = parseStages(await readFile(logFile, 'utf8'));
const from = stages[0].at - LEAD_MS;
await mkdir(framesDir, { recursive: true });

const atTime = (t) => `${url}&from=${from}&to=${t}`;

async function showAt(page, t) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      await showDashboard(page, atTime(t), { settleMs: 1000 });
      return;
    } catch (err) {
      if (attempt >= ATTEMPTS) throw err;
      console.error(`Кадр на ${new Date(t).toLocaleTimeString('ru-RU')}, попытка ${attempt}: ${err.message.split('\n')[0]}`);
      await sleep(RETRY_DELAY_MS);
      await signIn(page.context(), url).catch((loginErr) => console.error(loginErr.message));
    }
  }
}

const { browser, page } = await openGrafana(atTime(stages[0].at));
let frame = 0;
try {
  for (let t = stages[0].at; t <= end + TAIL_MS; t += stepMs) {
    await showAt(page, t);
    const current = stages.filter((stage) => stage.at <= t).at(-1);
    await page.evaluate(drawBanner, {
      stage: t > end ? 'Сценарий завершён' : current.title,
      command: t > end ? '' : current.command,
      clock: new Date(t).toLocaleTimeString('ru-RU', { hour12: false }),
    });
    frame += 1;
    await page.screenshot({ path: path.join(framesDir, `frame-${String(frame).padStart(5, '0')}.png`) });
  }
} finally {
  await browser.close();
}
console.log(`Кадров: ${frame} → ${framesDir}`);
