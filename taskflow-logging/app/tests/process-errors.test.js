import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

// Обработчики ставятся на process целиком, поэтому проверяем их в дочернем
// процессе node: он ставит те же обработчики, что и server.js, и падает.
async function runChild(crashCode) {
  const script = `
    import { createLogger } from ${JSON.stringify(new URL('../src/lib/logger.js', import.meta.url).href)};
    import { installProcessErrorHandlers } from ${JSON.stringify(new URL('../src/lib/process-errors.js', import.meta.url).href)};
    installProcessErrorHandlers(createLogger({ service: 't', version: '0', env: 'test', level: 'info' }));
    ${crashCode}
  `;
  try {
    await execFileAsync(process.execPath, ['--input-type=module', '-e', script], { timeout: 10_000 });
    assert.fail('child process must exit with an error');
  } catch (err) {
    assert.equal(err.code, 1, `exit code; stderr: ${err.stderr}`);
    const lines = String(err.stdout).split('\n').filter(Boolean);
    assert.equal(lines.length, 1, `exactly one JSON line in stdout, got: ${err.stdout}`);
    return { record: JSON.parse(lines[0]), stderr: String(err.stderr) };
  }
}

test('uncaughtException: одна JSON-запись level=error и выход с кодом 1', async () => {
  const { record, stderr } = await runChild("setTimeout(() => { throw new Error('async boom'); }, 0);");
  assert.equal(record.level, 'error');
  assert.equal(record.message, 'uncaught exception');
  assert.equal(record['error.message'], 'async boom');
  assert.match(record['error.stack'], /^Error: async boom\n/);
  assert.equal(stderr, '', 'стек не дублируется текстом в stderr');
});

test('unhandledRejection: причина не-Error заворачивается в Error', async () => {
  const { record } = await runChild("Promise.reject('plain reason');");
  assert.equal(record.level, 'error');
  assert.equal(record.message, 'unhandled rejection');
  assert.equal(record['error.message'], 'plain reason');
});
