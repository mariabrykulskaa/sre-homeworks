#!/usr/bin/env python3
"""Трафик через шлюз: какая версия TaskFlow ответила на каждый запрос.

Шлёт запросы с постоянной частотой (по умолчанию GET /api/projects — настоящий
запрос к API с походом в PostgreSQL) и раскладывает ответы по версиям из
заголовка X-App-Version. Раз в секунду печатает строку с распределением, в
конце — итог. Только стандартная библиотека Python.

Примеры:
  traffic.py --url http://127.0.0.1:8888 --host taskflow.local --duration 30
  traffic.py ... --requests 400 --quiet                      # только итог
  traffic.py ... -H 'X-User-Group: beta' --label beta         # аудитория B
"""

import argparse
import http.client
import queue
import signal
import sys
import threading
import time
import urllib.parse
from collections import Counter, defaultdict
from datetime import datetime, timezone

COLORS = ("\033[34m", "\033[32m", "\033[33m", "\033[35m")  # синий, зелёный, жёлтый, пурпурный
RED, DIM, BOLD, RESET = "\033[31m", "\033[2m", "\033[1m", "\033[0m"
NO_VERSION = "—"


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default="http://127.0.0.1:8888", help="адрес шлюза")
    p.add_argument("--host", default="taskflow.local", help="заголовок Host (имя в HTTPRoute)")
    p.add_argument("--path", default="/api/projects?limit=1")
    p.add_argument("-H", "--header", action="append", default=[], help="доп. заголовок 'Имя: значение'")
    p.add_argument("--rps", type=float, default=20, help="запросов в секунду")
    group = p.add_mutually_exclusive_group()
    group.add_argument("--duration", type=float, help="длительность, с")
    group.add_argument("--requests", type=int, help="число запросов")
    p.add_argument("--workers", type=int, default=8)
    p.add_argument("--versions", default="", help="версии через запятую — порядок колонок и цвета")
    p.add_argument("--label", default="", help="подпись строк (например, аудитория)")
    p.add_argument("--quiet", action="store_true", help="без построчного вывода, только итог")
    p.add_argument("--by-pod", action="store_true", help="в итоге — распределение по репликам")
    p.add_argument("--pods", action="store_true", help="в строках — сколько разных реплик ответило")
    args = p.parse_args(argv)
    if args.duration is None and args.requests is None:
        args.duration = 30
    return args


class Stats:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.by_second: dict[int, Counter] = defaultdict(Counter)
        self.pods_by_second: dict[int, dict[str, set]] = defaultdict(lambda: defaultdict(set))
        self.errors_by_second: Counter = Counter()
        self.versions: Counter = Counter()
        self.pods: Counter = Counter()
        self.pod_version: dict[str, str] = {}
        self.codes: Counter = Counter()
        self.total = 0
        self.errors = 0

    def record(self, second: int, version: str, pod: str, code: str, ok: bool) -> None:
        with self.lock:
            self.total += 1
            self.codes[code] += 1
            if ok:
                self.by_second[second][version] += 1
                self.versions[version] += 1
                if pod:
                    self.pods_by_second[second][version].add(pod)
                    self.pods[pod] += 1
                    self.pod_version[pod] = version
            else:
                self.errors += 1
                self.errors_by_second[second] += 1


def worker(args, extra_headers, tasks: queue.Queue, stats: Stats, started: float) -> None:
    target = urllib.parse.urlsplit(args.url)
    conn = None
    while True:
        item = tasks.get()
        if item is None:
            break
        try:
            if conn is None:
                conn = http.client.HTTPConnection(target.hostname, target.port or 80, timeout=5)
            conn.request("GET", args.path, headers={"Host": args.host, "User-Agent": "taskflow-traffic/1.0", **extra_headers})
            resp = conn.getresponse()
            resp.read()
            version = resp.getheader("X-App-Version") or NO_VERSION
            pod = resp.getheader("X-Served-By") or ""
            ok = 200 <= resp.status < 400
            code = str(resp.status)
            if resp.getheader("Connection", "").lower() == "close":
                conn.close()
                conn = None
        except (OSError, http.client.HTTPException) as err:
            version, pod, ok, code = NO_VERSION, "", False, type(err).__name__
            if conn is not None:
                conn.close()
            conn = None
        stats.record(int(time.monotonic() - started), version, pod, code, ok)


def bar(count: int, scale: float, width: int) -> str:
    filled = min(width, round(count / scale * width)) if scale else 0
    return "█" * filled + "·" * (width - filled)


def color_of(version: str, order: list[str]) -> str:
    if version == NO_VERSION:
        return RED
    if version not in order:
        order.append(version)
    return COLORS[order.index(version) % len(COLORS)]


def print_second(args, stats: Stats, second: int, order: list[str]) -> None:
    with stats.lock:
        counts = dict(stats.by_second.get(second, {}))
        pods = {v: len(p) for v, p in stats.pods_by_second.get(second, {}).items()}
        errors = stats.errors_by_second.get(second, 0)
    for version in counts:
        color_of(version, order)
    parts = []
    for version in order:
        n = counts.get(version, 0)
        cell = f"{color_of(version, order)}{version} {bar(n, args.rps, 20)} {n:3d}{RESET}"
        if args.pods:
            cell += f"{DIM} [{pods.get(version, 0)}]{RESET}"
        parts.append(cell)
    err = f"{RED}ошибок {errors}{RESET}" if errors else f"{DIM}ошибок 0{RESET}"
    label = f"{args.label} " if args.label else ""
    # UTC — как в логах Envoy и приложения: строки сопоставляются по времени.
    stamp = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"{DIM}{label}{stamp}{RESET}  " + "  ".join(parts) + f"  {err}", flush=True)


def print_summary(args, stats: Stats, elapsed: float, order: list[str]) -> None:
    label = f" [{args.label}]" if args.label else ""
    share = stats.errors / stats.total * 100 if stats.total else 0.0
    err_color = RED if stats.errors else ""
    print(f"{BOLD}Итого{label}: {stats.total} запросов за {elapsed:.1f} с, "
          f"{err_color}ошибок {stats.errors} ({share:.2f} %){RESET}", flush=True)
    for version in stats.versions:
        color_of(version, order)
    for version in order:
        n = stats.versions.get(version, 0)
        pct = n / stats.total * 100 if stats.total else 0.0
        print(f"  {color_of(version, order)}{version:>7} {bar(n, stats.total, 40)} {n:5d}  {pct:5.1f} %{RESET}")
    if stats.errors:
        codes = ", ".join(f"{c}: {n}" for c, n in sorted(stats.codes.items()) if not c.startswith(("2", "3")))
        print(f"  {RED}коды ошибок — {codes}{RESET}")
    if args.by_pod and stats.pods:
        print("  по репликам:")
        for pod, n in sorted(stats.pods.items(), key=lambda kv: (stats.pod_version[kv[0]], kv[0])):
            version = stats.pod_version[pod]
            print(f"    {color_of(version, order)}{pod:<38} {version:>7} {n:5d}{RESET}")
    sys.stdout.flush()


def main(argv=None) -> int:
    args = parse_args(argv)
    extra_headers = {}
    for raw in args.header:
        name, sep, value = raw.partition(":")
        if not sep:
            raise SystemExit(f"заголовок без двоеточия: {raw!r}")
        extra_headers[name.strip()] = value.strip()
    order = [v for v in args.versions.split(",") if v]

    stats = Stats()
    tasks: queue.Queue = queue.Queue()
    started = time.monotonic()
    threads = [
        threading.Thread(target=worker, args=(args, extra_headers, tasks, stats, started), daemon=True)
        for _ in range(args.workers)
    ]
    for t in threads:
        t.start()

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())

    interval = 1.0 / args.rps
    sent = 0
    printed = 0
    next_send = started
    while not stop.is_set():
        now = time.monotonic()
        elapsed = now - started
        if args.duration is not None and elapsed >= args.duration:
            break
        if args.requests is not None and sent >= args.requests:
            break
        if now >= next_send:
            tasks.put(sent)
            sent += 1
            next_send += interval
        # Строка за прошлую секунду — с запасом 0.3 с на последние ответы.
        if not args.quiet and elapsed - 0.3 >= printed + 1:
            print_second(args, stats, printed, order)
            printed += 1
        time.sleep(max(0.0, min(next_send - time.monotonic(), 0.02)))

    for _ in threads:
        tasks.put(None)
    for t in threads:
        t.join(timeout=6)
    elapsed = time.monotonic() - started
    if not args.quiet:
        while printed < int(elapsed):
            print_second(args, stats, printed, order)
            printed += 1
    print_summary(args, stats, elapsed, order)
    return 0


if __name__ == "__main__":
    sys.exit(main())
