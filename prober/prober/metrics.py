"""Метрики пробера — сырьё для SLI «доступность для пользователя»:

  prober_probe_runs_total{probe, result}            запуски проб: success | failure
  prober_probe_failures_total{probe, step, reason}  на каком шаге и почему проба упала
  prober_probe_success{probe}                       итог последнего запуска (1/0)
  prober_probe_duration_seconds{probe}              длительность успешных запусков
  prober_internal_errors_total{probe}               сбои самого пробера (баг в коде) —
                                                    такие запуски в SLI не идут вовсе
Плюс рантайм Python (процесс, сборщик мусора), как у TaskFlow.
"""

from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    GCCollector,
    Histogram,
    PlatformCollector,
    ProcessCollector,
    disable_created_metrics,
)

FAILURE_REASONS = ("timeout", "connection", "server_error", "unexpected_status", "invalid_body")

disable_created_metrics()


class ProberMetrics:
    """Отдельный реестр на экземпляр: в тестах у каждого пробера свои счётчики."""

    def __init__(self, probes) -> None:
        self.registry = CollectorRegistry()
        ProcessCollector(registry=self.registry)
        GCCollector(registry=self.registry)
        PlatformCollector(registry=self.registry)
        r = self.registry
        self.runs = Counter("prober_probe_runs", "Probe runs, by result (success or failure)", ["probe", "result"], registry=r)
        self.failures = Counter(
            "prober_probe_failures", "Failed probe runs, by the step that failed and the reason",
            ["probe", "step", "reason"], registry=r,
        )
        self.success = Gauge("prober_probe_success", "Whether the last run of the probe succeeded (1) or failed (0)", ["probe"], registry=r)
        self.duration = Histogram(
            "prober_probe_duration_seconds", "Duration of successful probe runs", ["probe"],
            buckets=(0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10), registry=r,
        )
        self.internal_errors = Counter(
            "prober_internal_errors",
            "Probe runs aborted by a bug in the prober itself; not counted as success or failure",
            ["probe"], registry=r,
        )
        # Ряды заводятся заранее со значением 0: первая ошибка — переход 0 → 1,
        # и increase() его засчитывает.
        for probe in probes:
            self.runs.labels(probe=probe.name, result="success")
            self.runs.labels(probe=probe.name, result="failure")
            self.internal_errors.labels(probe=probe.name)
            for step in probe.steps:
                for reason in FAILURE_REASONS:
                    self.failures.labels(probe=probe.name, step=step, reason=reason)

    def record_success(self, probe: str, seconds: float) -> None:
        self.runs.labels(probe=probe, result="success").inc()
        self.success.labels(probe=probe).set(1)
        self.duration.labels(probe=probe).observe(seconds)

    def record_failure(self, probe: str, step: str, reason: str) -> None:
        self.runs.labels(probe=probe, result="failure").inc()
        self.failures.labels(probe=probe, step=step, reason=reason).inc()
        self.success.labels(probe=probe).set(0)

    def record_internal_error(self, probe: str) -> None:
        self.internal_errors.labels(probe=probe).inc()
