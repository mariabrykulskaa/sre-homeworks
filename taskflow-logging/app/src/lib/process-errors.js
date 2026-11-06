// Последняя линия обороны: необработанное исключение или отклонённый промис без
// catch. Состояние процесса после такого непредсказуемо, поэтому Node по
// умолчанию завершает его — но пишет стек в stderr обычным текстом, и в
// Victoria Logs он пришёл бы без level, service.name и прочих полей схемы.
// Здесь событие уходит в тот же JSON-поток, что и всё остальное, а процесс
// завершается с кодом 1 — оркестратор перезапустит под (IX. Утилизируемость).
const EXIT_CODE = 1;

function asError(reason) {
  return reason instanceof Error ? reason : new Error(String(reason));
}

export function installProcessErrorHandlers(logger, { exit = (code) => process.exit(code) } = {}) {
  process.on('uncaughtException', (err) => {
    logger.error('uncaught exception', { error: asError(err) });
    exit(EXIT_CODE);
  });
  process.on('unhandledRejection', (reason) => {
    logger.error('unhandled rejection', { error: asError(reason) });
    exit(EXIT_CODE);
  });
}
