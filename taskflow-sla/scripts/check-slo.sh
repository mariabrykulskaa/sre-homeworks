#!/usr/bin/env bash
# Печатает текущие SLI, SLO и SLA TaskFlow — те же ряды slo:*, что считает vmalert
# и рисует дашборд Grafana. Запросы и формулы — Отчёт.md, разделы 3–6.
#
# Нужен туннель к VictoriaMetrics: scripts/port-forward.sh (в отдельном терминале).
#
# Использование: scripts/check-slo.sh [раздел]
#   раздел: sli | slo | sla | alerts | all (по умолчанию all)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

SECTION="${1:-all}"
case "$SECTION" in
  sli|slo|sla|alerts|all) ;;
  *) echo "Неизвестный раздел: $SECTION (sli | slo | sla | alerts | all)" >&2; exit 2 ;;
esac

require_tools curl python3
require_tunnel "$VM_URL/health" VictoriaMetrics

# Python — только для запросов к API и форматирования таблиц; вся логика SLO
# в правилах vmalert, здесь она не повторяется.
python3 -I - "$VM_URL" "$SECTION" <<'PY'
import calendar
import datetime as dt
import json
import sys
import urllib.parse
import urllib.request

VM, SECTION = sys.argv[1], sys.argv[2]
SLOS = ["availability", "latency", "probes", "database", "service"]


def query(expr):
    """Мгновенный запрос: {значение метки slo (или sli) → число}."""
    url = f"{VM}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=10) as resp:
        body = json.load(resp)
    if body.get("status") != "success":
        sys.exit(f"ошибка запроса {expr!r}: {body.get('error', '?')}")
    out = {}
    for row in body["data"]["result"]:
        key = row["metric"].get("slo") or row["metric"].get("sli") or ""
        out[key] = float(row["value"][1])
    return out


def pct(value, digits=3):
    return "—" if value is None else f"{value * 100:.{digits}f} %"


def num(value, digits=1):
    return "—" if value is None else f"{value:.{digits}f}"


def table(header, rows):
    widths = [max(len(str(r[i])) for r in [header, *rows]) for i in range(len(header))]
    line = lambda r: "  ".join(str(c).ljust(w) for c, w in zip(r, widths))
    print(line(header))
    print(line(["─" * w for w in widths]))
    for r in rows:
        print(line(r))


def section(name, title):
    if SECTION in ("all", name):
        print(f"\n=== {title}")
        return True
    return False


if section("sli", "SLI за последнюю минуту (ряды slo:events_*:increase1m, slo:minute_bad)"):
    total = query("slo:events_total:increase1m")
    bad = query("slo:events_bad:increase1m")
    verdict = query("slo:minute_bad")
    rows = []
    for slo in ["availability", "latency", "probes"]:
        t, b = total.get(slo), bad.get(slo)
        good = None if not t or b is None else 1 - b / t
        rows.append([slo, "request", num(t, 0), num(b, 0), pct(good, 2),
                     {0: "хорошая", 1: "плохая"}.get(verdict.get(slo), "—")])
    db = verdict.get("database")
    rows.append(["database", "time", "1 мин", num(db, 0), "—", {0: "хорошая", 1: "плохая"}.get(db, "—")])
    svc = bad.get("service")
    rows.append(["service", "time", "1 мин", num(svc, 0), "—", {0: "хорошая", 1: "плохая"}.get(svc, "—")])
    table(["SLI", "подход", "событий", "плохих", "хороших", "минута"], rows)

if section("slo", "SLO: цель, факт за 30 дней, остаток бюджета, скорость его расходования"):
    objective = query("slo:objective:ratio")
    ratio30d = query("slo:error_ratio:30d")
    budget = query("slo:error_budget_remaining:ratio")
    burn1h = query("slo:error_ratio:1h / on(slo) (1 - slo:objective:ratio)")
    burn5m = query("slo:error_ratio:5m / on(slo) (1 - slo:objective:ratio)")
    rows = []
    for slo in SLOS:
        fact = None if slo not in ratio30d else 1 - ratio30d[slo]
        ok = "—" if fact is None or slo not in objective else ("да" if fact >= objective[slo] else "НЕТ")
        rows.append([slo, pct(objective.get(slo), 1), pct(fact), ok, pct(budget.get(slo), 1),
                     num(burn1h.get(slo)), num(burn5m.get(slo))])
    table(["SLO", "цель", "факт 30d", "выполнен", "бюджет", "burn 1h", "burn 5m"], rows)
    print("burn rate: 1 — бюджет кончится ровно к концу 30 дней; алерты — > 14.4 (1h и 5m), > 6 (6h и 30m)")

if section("sla", "SLA: общая доступность (TBSLO service), обязательство — не ниже 99.0 % за месяц"):
    sla = query("sla:objective:ratio").get("service")
    rolling = query('1 - slo:error_ratio:30d{slo="service"}').get("service")
    now = dt.datetime.now(dt.timezone.utc)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    month_minutes = calendar.monthrange(now.year, now.month)[1] * 24 * 60
    elapsed = max(1, int((now - month_start).total_seconds() // 60))
    down = query(f'sum_over_time(slo:events_bad:increase1m{{slo="service"}}[{elapsed}m])').get("service", 0.0)
    allowed = None if sla is None else (1 - sla) * month_minutes
    month_avail = 1 - down / month_minutes
    print(f"Скользящее окно 30 дней:          {pct(rolling)}  (цель SLA {pct(sla, 1)})")
    print(f"Календарный месяц {now:%Y-%m} (UTC): {pct(month_avail)} — плохих минут {down:.0f}"
          f" из {month_minutes}, допускается {num(allowed, 0)}")
    if sla is not None:
        status = "пока соблюдается" if month_avail >= sla else "НАРУШЕН — клиентам положена компенсация"
        print(f"SLA за месяц: {status}")

if section("alerts", "Алерты vmalert (ряд ALERTS в VictoriaMetrics)"):
    url = f"{VM}/api/v1/query?" + urllib.parse.urlencode({"query": 'ALERTS{alertstate="firing"}'})
    with urllib.request.urlopen(url, timeout=10) as resp:
        rows = json.load(resp)["data"]["result"]
    if not rows:
        print("нет активных алертов")
    for row in sorted(rows, key=lambda r: (r["metric"].get("alertname", ""), r["metric"].get("slo", ""))):
        m = row["metric"]
        print(f"{m.get('severity', '?'):9} {m.get('alertname', '?'):24} slo={m.get('slo', '?')}")
PY
