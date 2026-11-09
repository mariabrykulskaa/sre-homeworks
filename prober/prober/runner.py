"""Запуск проб: один запуск с учётом в метриках и логах (run_probe) и циклы,
которые повторяют каждую пробу раз в интервал (probe_loops)."""

import asyncio
import time

from .probes import Probe, ProbeContext, ProbeFailure


async def run_probe(probe: Probe, ctx: ProbeContext, metrics, logger) -> dict:
    """Никогда не бросает: результат — {"ok": bool, "step"?, "reason"?, "internal"?}."""
    fields = {"probe": probe.name, "run_id": ctx.run_id}
    try:
        if probe.prepare:
            await probe.prepare(ctx)
        started = time.perf_counter()
        try:
            await probe.run(ctx)
        except ProbeFailure as err:
            metrics.record_failure(probe.name, err.step, err.reason)
            logger.warn(
                "probe failed", **fields, step=err.step, reason=err.reason, status=err.status,
                request_id=err.request_id, duration_ms=round((time.perf_counter() - started) * 1000), error=err,
            )
            return {"ok": False, "step": err.step, "reason": err.reason}
        seconds = time.perf_counter() - started
        metrics.record_success(probe.name, seconds)
        logger.debug("probe succeeded", **fields, duration_ms=round(seconds * 1000))
        return {"ok": True}
    except Exception as err:  # noqa: BLE001
        # Ошибка в коде пробера — не сбой TaskFlow: в SLI такой запуск не идёт.
        metrics.record_internal_error(probe.name)
        logger.error("probe crashed", **fields, error=err)
        return {"ok": False, "internal": True}


async def probe_loops(probes, interval_seconds: float, run, stop: asyncio.Event) -> None:
    """Каждая проба — в своём цикле: запуск, затем пауза до конца интервала.
    Запуски одной пробы не накладываются. Пробы стартуют со сдвигом, чтобы не
    ходить в приложение одновременно. Возвращается, когда stop выставлен и
    текущие запуски доведены до конца."""

    async def pause(seconds: float) -> None:
        try:
            await asyncio.wait_for(stop.wait(), max(0.0, seconds))
        except asyncio.TimeoutError:
            pass

    async def loop(probe: Probe, index: int) -> None:
        await pause(index * interval_seconds / len(probes))
        while not stop.is_set():
            started = time.perf_counter()
            await run(probe)
            await pause(interval_seconds - (time.perf_counter() - started))

    await asyncio.gather(*(loop(p, i) for i, p in enumerate(probes)))
