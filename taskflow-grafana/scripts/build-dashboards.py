#!/usr/bin/env python3
"""Build the application dashboard and adapt Grafana.com dashboard 9628/r8."""
import copy
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'k8s/monitoring/dashboards'
DS = {'type': 'prometheus', 'uid': 'victoriametrics'}
API = 'job="taskflow",route=~"/api/(projects|tasks).*|unmatched"'
POD = 'job="taskflow",pod=~"$pod"'
TOTAL = f'sum(rate(http_request_duration_seconds_count{{{API}}}[$__rate_interval]))'
ERRORS = f'(sum(rate(http_request_duration_seconds_count{{{API},status_code=~"5.."}}[$__rate_interval])) or on() (0 * {TOTAL}))'


def target(expr, legend='', instant=False):
    return {'expr': expr, 'legendFormat': legend, 'instant': instant,
            'range': not instant, 'editorMode': 'code', 'datasource': DS}


def panel(pid, title, pos, queries, unit='short', kind='timeseries', description='', thresholds=None, decimals=None):
    defaults = {'unit': unit, 'color': {'mode': 'palette-classic'}, 'noValue': 'Нет данных'}
    if decimals is not None:
        defaults['decimals'] = decimals
    if thresholds:
        defaults['thresholds'] = {'mode': 'absolute', 'steps': [
            {'color': color, 'value': value} for color, value in thresholds]}
    if kind == 'timeseries':
        defaults['custom'] = {'drawStyle': 'line', 'lineInterpolation': 'linear',
                              'lineWidth': 2, 'fillOpacity': 10, 'showPoints': 'never',
                              'spanNulls': False, 'axisCenteredZero': False,
                              'thresholdsStyle': {'mode': 'dashed' if thresholds else 'off'}}
        options = {'legend': {'displayMode': 'table', 'placement': 'bottom',
                               'calcs': ['lastNotNull'], 'showLegend': True},
                   'tooltip': {'mode': 'multi', 'sort': 'desc'}}
    else:
        defaults['color'] = {'mode': 'thresholds' if thresholds else 'fixed', 'fixedColor': 'blue'}
        options = {'reduceOptions': {'calcs': ['lastNotNull'], 'fields': '', 'values': False},
                   'orientation': 'horizontal', 'textMode': 'auto', 'colorMode': 'value',
                   'graphMode': 'none', 'justifyMode': 'auto'}
    for i, query in enumerate(queries):
        query['refId'] = chr(65 + i)
    x, y, w, h = pos
    return {'id': pid, 'title': title, 'description': description, 'type': kind,
            'datasource': DS, 'gridPos': {'x': x, 'y': y, 'w': w, 'h': h},
            'fieldConfig': {'defaults': defaults, 'overrides': []},
            'options': options, 'targets': queries}


def row(pid, title, y):
    return {'id': pid, 'title': title, 'type': 'row', 'collapsed': False,
            'gridPos': {'x': 0, 'y': y, 'w': 24, 'h': 1}, 'panels': []}


def quantile(q):
    return f'histogram_quantile({q}, sum by (le) (rate(http_request_duration_seconds_bucket{{{API}}}[$__rate_interval])))'


def application():
    panels = [row(100, '01 · Состояние приложения / RED и Golden Signals', 0)]
    stats = [
        (1, 'Реплики · UP', 'sum(up{job="taskflow"})', 'short',
         'Количество реплик, с которых vmagent успешно забирает метрики. Ожидается 2. Это доступность metrics endpoint, а доступность API проверяет пробер.', [('red', None), ('orange', 1), ('green', 2)], 0),
        (2, 'API · RPS', TOTAL, 'reqps',
         'RED: Rate. Только пользовательские маршруты API; health, readiness и статика исключены.', None, 2),
        (3, 'API · 5xx', f'{ERRORS} / {TOTAL}', 'percentunit',
         'RED: Errors. Ошибки сервера / все ответы API. Ноль при отсутствии ряда 5xx; при отсутствии трафика процент не определён.', [('green', None), ('orange', .01), ('red', .05)], 2),
        (4, 'API · p95', quantile(.95), 's',
         'RED: Duration. Перцентиль общей гистограммы реплик. Ориентир 250 мс соответствует SLI из ДЗ №5.', [('green', None), ('orange', .25), ('red', 1)], 3),
        (5, 'PostgreSQL · UP', 'min(pg_up{job="postgres"})', 'short',
         'Экспортер успешно подключился к PostgreSQL и выполнил запрос статистики: 1 = доступна, 0 = ошибка.', [('red', None), ('green', 1)], 0),
        (6, 'Пробер · UP', 'min(up{job="taskflow-prober"})', 'short',
         'Контроль самого измерителя: недоступный пробер не должен выглядеть как 100% успешных проверок.', [('red', None), ('green', 1)], 0),
    ]
    for i, (pid, title, expr, unit, desc, thresholds, decimals) in enumerate(stats):
        panels.append(panel(pid, title, (i * 4, 1, 4, 4), [target(expr, instant=True)], unit, 'stat', desc, thresholds, decimals))
    panels += [
        panel(7, 'Rate · RPS по HTTP-статусам', (0, 5, 8, 8), [target(f'sum by (status_code) (rate(http_request_duration_seconds_count{{{API}}}[$__rate_interval]))', '{{status_code}}')], 'reqps', description='Объём трафика и распределение 2xx / 4xx / 5xx. 4xx видны отдельно и не считаются отказом сервера.'),
        panel(8, 'Errors · доля 5xx и 4xx', (8, 5, 8, 8), [target(f'{ERRORS} / {TOTAL}', '5xx · сервер'), target(f'sum(rate(http_request_duration_seconds_count{{{API},status_code=~"4.."}}[$__rate_interval])) / {TOTAL}', '4xx · клиент')], 'percentunit', description='Golden Signal: ошибки. Показываем долю, чтобы рост трафика не выглядел ростом вероятности отказа.'),
        panel(9, 'Duration · p50 / p95 / p99', (16, 5, 8, 8), [target(quantile(q), label) for q, label in [(.5, 'p50'), (.95, 'p95'), (.99, 'p99')]], 's', description='Golden Signal: задержка. rate() до sum() сохраняет корректность при перезапусках; перцентили считаются из общих bucket, а не усредняются по репликам.', thresholds=[('green', None), ('orange', .25)]),
        row(101, '02 · Рантайм Python / ресурсы процесса', 13),
        panel(10, 'CPU процесса · ядра', (0, 14, 8, 8), [target(f'rate(process_cpu_seconds_total{{{POD}}}[$__rate_interval])', '{{pod}}')], description='USE: utilization. Скорость роста CPU time — число занятых ядер. У контейнера нет CPU limit: это не процент от квоты и не измерение throttling.'),
        panel(11, 'Память Python · RSS и лимит', (8, 14, 8, 8), [target(f'process_resident_memory_bytes{{{POD}}}', '{{pod}} · RSS'), target('vector(256 * 1024 * 1024)', 'лимит контейнера · 256 MiB')], 'bytes', description='Резидентная память процесса. Лимит 256 MiB взят из k8s/app/20-app.yaml. RSS не равен полной памяти cgroup; лимит задан в запросе, поскольку kube-state-metrics в стенде нет.'),
        panel(12, 'Файловые дескрипторы · использование', (16, 14, 8, 8), [target(f'process_open_fds{{{POD}}} / process_max_fds{{{POD}}}', '{{pod}}')], 'percentunit', description='USE: доля занятого ресурса относительно process_max_fds. При приближении к лимиту процесс не сможет открывать соединения и файлы.'),
        panel(13, 'GC Python · сборок в секунду', (0, 22, 8, 8), [target(f'sum by (generation) (rate(python_gc_collections_total{{{POD}}}[$__rate_interval]))', 'поколение {{generation}}')], 'ops', description='Готовый GCCollector prometheus_client: частота сборок по поколениям. Помогает объяснить изменения памяти и CPU; сама частота не считается ошибкой.'),
        panel(14, 'GC Python · освобождённых объектов / с', (8, 22, 8, 8), [target(f'sum by (generation) (rate(python_gc_objects_collected_total{{{POD}}}[$__rate_interval]))', 'поколение {{generation}}')], 'ops', description='Сколько объектов освобождает GC. Сопоставляем с RSS: рост RSS без освобождения объектов требует проверки утечки.'),
        panel(15, 'Процесс Python · время работы', (16, 22, 8, 8), [target(f'time() - process_start_time_seconds{{{POD}}}', '{{pod}}')], 's', description='Сброс времени работы помогает увидеть перезапуск процесса при разборе падения, OOM или выкатки.'),
        row(102, '03 · SLA и внешний взгляд пробера', 30),
        panel(16, 'SLA пробера · 30 дней', (0, 31, 6, 5), [target('1 - slo:error_ratio:30d{slo="probes"}', instant=True)], 'percentunit', 'stat', 'Отдельная панель доступности по проберу: 1 − сумма неуспешных запусков / сумма всех запусков за 30d. Используются recording rules ДЗ №5, а не среднее процентов. Сравнение с внешней целью 99%; внутренний SLO probes — 99,5%. История короче 30d: показан результат по накопленным данным.', [('red', None), ('green', .99)], 3),
        panel(17, 'Цель SLA', (6, 31, 6, 5), [target('scalar(sla:objective:ratio{slo="service"})', instant=True)], 'percentunit', 'stat', '99% берётся из правил ДЗ №5, а не дублируется в запросе как константа. Официальный SLA сервиса считается по хорошим минутам; успешность пробера — дополнительный независимый индикатор.', None, 2),
        panel(18, 'SLA сервиса · 30 дней', (12, 31, 6, 5), [target('1 - slo:error_ratio:30d{slo="service"}', instant=True)], 'percentunit', 'stat', 'Исходный TBSLA из ДЗ №5: 1 − плохие минуты / 43200. Минута плохая при нарушении хотя бы одного SLI. Этот показатель имеет другой знаменатель, чем успешность проб; оба показаны явно.', [('red', None), ('green', .99)], 3),
        panel(19, 'Покрытие окна · дни', (18, 31, 6, 5), [target('count_over_time(slo:events_total:increase1m{slo="probes"}[30d]) / 1440', instant=True)], 'short', 'stat', 'Число записанных минут за окно / 1440. 30d — целевое окно; эта карточка показывает фактическое покрытие. Пропуски наблюдений не выдаются за полноценный месячный результат.', None, 2),
        panel(20, 'Пробы · успешность за 5 минут', (0, 36, 8, 8), [target('sum by (probe) (rate(prober_probe_runs_total{job="taskflow-prober",result="success"}[5m])) / sum by (probe) (rate(prober_probe_runs_total{job="taskflow-prober"}[5m]))', '{{probe}}'), target('scalar(sla:objective:ratio{slo="service"})', 'ориентир SLA · 99%')], 'percentunit', description='Клиентский взгляд: list_projects и task_lifecycle проверяют чтение, создание и удаление данных через Service. Текущее качество видно отдельно от накопленного результата 30d.'),
        panel(21, 'Пробы · длительность p95', (8, 36, 8, 8), [target('histogram_quantile(0.95, sum by (le, probe) (rate(prober_probe_duration_seconds_bucket{job="taskflow-prober"}[$__rate_interval])))', '{{probe}}')], 's', description='Длительность успешного сценария целиком. Это клиентская задержка нескольких HTTP-вызовов, а не серверная задержка одного запроса.'),
        panel(22, 'Пробы · ошибки по причинам / с', (16, 36, 8, 8), [target('sum by (probe, reason) (rate(prober_probe_failures_total{job="taskflow-prober"}[$__rate_interval]))', '{{probe}} · {{reason}}')], 'ops', description='Различаем timeout, connection, server_error, unexpected_status и invalid_body, чтобы понять, какой компонент проверять.'),
        row(103, '04 · Метрики продукта / результат пользовательских действий', 44),
        panel(23, 'Задачи · создано в минуту', (0, 45, 8, 8), [target('sum by (status) (rate(taskflow_tasks_created_total{job="taskflow"}[$__rate_interval])) * 60', '{{status}}')], 'short', description='Бизнес-события после успешной записи в БД. Помогают отличить HTTP-трафик от фактически выполненных действий; на стенде часть действий создаёт пробер.'),
        panel(24, 'Задачи · переходов статуса в минуту', (8, 45, 8, 8), [target('sum by (from, to) (rate(taskflow_task_status_transitions_total{job="taskflow"}[$__rate_interval])) * 60', '{{from}} → {{to}}')], 'short', description='Показывает, какие действия выполняют пользователи и пробер. При отсутствии переходов нулевые значения ожидаемы.'),
        panel(25, 'Задачи · время до завершения p95', (16, 45, 8, 8), [target('histogram_quantile(0.95, sum by (le) (rate(taskflow_task_lead_time_seconds_bucket{job="taskflow"}[$__rate_interval])))', 'p95')], 's', description='Гистограмма жизненного цикла задачи. Широкие корзины рассчитаны на настоящие задачи; у коротких синтетических задач оценка ограничена шириной первой корзины, поэтому для HTTP latency используется другая гистограмма.'),
    ]
    return {
        'id': None, 'uid': 'taskflow-overview', 'title': 'TaskFlow · приложение, Python и SLA',
        'description': 'Домашняя работа Grafana: RED / Golden Signals, ресурсы Python, SLA пробера и бизнес-метрики. Источник — VictoriaMetrics; PostgreSQL открыт по ссылке справа.',
        'tags': ['taskflow', 'grafana-homework', 'RED', 'Python', 'SLA'],
        'schemaVersion': 39, 'version': 1, 'editable': True, 'timezone': 'Europe/Moscow',
        'time': {'from': 'now-1h', 'to': 'now'}, 'refresh': '15s', 'fiscalYearStartMonth': 0,
        'annotations': {'list': []}, 'panels': panels,
        'templating': {'list': [{'name': 'pod', 'label': 'Python · Pod', 'type': 'query',
                                'datasource': DS, 'query': 'label_values(up{job="taskflow"}, pod)',
                                'refresh': 1, 'includeAll': True, 'allValue': '.*', 'multi': True,
                                'current': {'text': 'All', 'value': '$__all'}, 'options': [], 'sort': 1}]},
        'links': [{'title': 'PostgreSQL Exporter ↗', 'type': 'link', 'url': '/d/taskflow-postgresql', 'keepTime': True},
                  {'title': 'SLI / SLO / SLA · ДЗ №5 ↗', 'type': 'link', 'url': '/d/taskflow-slo', 'keepTime': True}],
    }


def postgres():
    original = json.loads((ROOT / 'dashboards/upstream/postgresql-9628-r8.json').read_text())
    result = copy.deepcopy(original)
    result.update(id=None, uid='taskflow-postgresql', title='PostgreSQL Database · TaskFlow / импорт 9628',
                  schemaVersion=39, version=1, timezone='Europe/Moscow', refresh='15s',
                  description='Импорт Grafana.com 9628, revision 8 (Lucas Estienne). Адаптация меток service discovery и устаревших панелей под Grafana 13 / PostgreSQL 17; исходный JSON сохранён в dashboards/upstream/. CPU/RSS/FD здесь принадлежат экспортеру, не процессу PostgreSQL.',
                  time={'from': 'now-1h', 'to': 'now'}, tags=['postgresql', 'taskflow', 'imported-9628'])
    result.pop('__inputs', None)
    result.pop('__requires', None)
    result['annotations'] = {'list': []}
    result['links'] = [{'title': 'TaskFlow · приложение и SLA ↗', 'type': 'link', 'url': '/d/taskflow-overview', 'keepTime': True},
                       {'title': 'Оригинал · Grafana.com 9628 ↗', 'type': 'link', 'url': 'https://grafana.com/grafana/dashboards/9628-postgresql-database/', 'targetBlank': True}]
    def variable(name, label, query, default='All', multi=False):
        return {'name': name, 'label': label, 'type': 'query', 'datasource': DS,
                'query': query, 'refresh': 1, 'includeAll': multi, 'allValue': '.*' if multi else None,
                'multi': multi, 'current': {'text': default, 'value': '$__all' if default == 'All' else default}, 'options': [], 'sort': 1}
    result['templating'] = {'list': [
        variable('instance', 'Экспортер PostgreSQL', 'label_values(pg_up{job="postgres"}, instance)', multi=True),
        variable('datname', 'База данных', 'label_values(pg_stat_database_numbackends{job="postgres",instance=~"$instance"}, datname)', 'taskflow', True),
        variable('mode', 'Тип блокировки', 'label_values(pg_locks_count{job="postgres",instance=~"$instance"}, mode)', multi=True),
    ]}
    panels = []
    for old in result['panels']:
        if old['type'] == 'row':
            labels = {34: '01 · PostgreSQL и процесс экспортера', 32: '02 · Настройки PostgreSQL', 30: '03 · Работа базы данных / postgres-exporter'}
            panels.append(row(old['id'], labels[old['id']], old['gridPos']['y']))
            continue
        queries = []
        for item in old.get('targets', []):
            expr = item.get('expr', '')
            expr = re.sub(r'release="\$release",?\s*', '', expr)
            expr = expr.replace('instance="$instance"', 'instance=~"$instance"')
            expr = expr.replace('{', '{job="postgres",')
            expr = expr.replace('[5m]', '[$__rate_interval]').replace('SUM(', 'sum(')
            expr = re.sub(r'\s*!=\s*0', '', expr)
            queries.append(target(expr, item.get('legendFormat') or old['title'], old['type'] == 'singlestat'))
        pos = old['gridPos']
        unit = old.get('format', old.get('yaxes', [{}])[0].get('format', 'short'))
        if old['id'] in (10, 11, 12):
            unit = 'short'
        kind = 'stat' if old['type'] == 'singlestat' else 'timeseries'
        replacement = panel(old['id'], old['title'], (pos['x'], pos['y'], pos['w'], max(pos['h'], 4) if kind == 'stat' else pos['h']), queries, unit,
                            kind, 'Импортированный дашборд 9628/r8; запрос адаптирован к меткам vmagent (job=postgres, instance).')
        panels.append(replacement)
    by_id = {p['id']: p for p in panels}
    def replace(pid, title, queries, unit, desc):
        p = by_id[pid]
        by_id[pid] = panel(pid, title, tuple(p['gridPos'][key] for key in ('x', 'y', 'w', 'h')),
                          queries, unit, p['type'], desc)
    replace(36, 'PostgreSQL · UP', [target('min(pg_up{job="postgres",instance=~"$instance"})', instant=True)], 'short', 'Вместо pg_static (отсутствует в этой конфигурации экспортера) показан реальный pg_up. 1 — БД отвечает.')
    replace(28, 'Экспортер · время работы', [target('time() - min(process_start_time_seconds{job="postgres",instance=~"$instance"})', instant=True)], 's', 'Процесс postgres-exporter, не postmaster. Коллектор postmaster в стенде не включён.')
    replace(22, 'Экспортер · CPU, ядра', [target('rate(process_cpu_seconds_total{job="postgres",instance=~"$instance"}[$__rate_interval])', '{{instance}}')], 'short', 'process_* принадлежат экспортеру. Здесь число занятых CPU-ядер; это не CPU самого PostgreSQL.')
    replace(24, 'Экспортер · RSS и виртуальная память', [target('process_resident_memory_bytes{job="postgres",instance=~"$instance"}', 'RSS'), target('process_virtual_memory_bytes{job="postgres",instance=~"$instance"}', 'virtual')], 'bytes', 'Память — gauge: показывается значение, не rate(). Это память postgres-exporter.')
    replace(26, 'Экспортер · открытые дескрипторы', [target('process_open_fds{job="postgres",instance=~"$instance"}', '{{instance}}')], 'short', 'Дескрипторы процесса postgres-exporter.')
    replace(64, 'Buffers · bgwriter / с', [target('rate(pg_stat_bgwriter_buffers_alloc_total{job="postgres",instance=~"$instance"}[$__rate_interval])', 'allocated'), target('rate(pg_stat_bgwriter_buffers_clean_total{job="postgres",instance=~"$instance"}[$__rate_interval])', 'cleaned')], 'ops', 'В PostgreSQL 17 часть статистики перемещена из bgwriter в checkpointer. Оставлены метрики реально включённых коллекторов, без пустых старых рядов.')
    replace(70, 'I/O PostgreSQL · время чтения / записи', [target('rate(pg_stat_database_blk_read_time{job="postgres",instance=~"$instance",datname=~"$datname"}[$__rate_interval]) / 1000', '{{datname}} · read'), target('rate(pg_stat_database_blk_write_time{job="postgres",instance=~"$instance",datname=~"$datname"}[$__rate_interval]) / 1000', '{{datname}} · write')], 's', 'Вместо отсутствующих legacy checkpoint-метрик — доступные blk_read_time / blk_write_time (мс преобразованы в секунды). Если track_io_timing выключен, ноль ожидаем и не означает нулевую физическую задержку диска.')
    # Увеличенные stat-панели не должны перекрывать следующий ряд.
    for p in by_id.values():
        y = p['gridPos']['y']
        if y >= 3:
            p['gridPos']['y'] += 2
        if y >= 14:
            p['gridPos']['y'] += 1
    result['panels'] = [by_id[p['id']] for p in panels]
    return result


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    for name, dashboard in [('taskflow-overview.json', application()), ('postgresql-exporter.json', postgres())]:
        (OUT / name).write_text(json.dumps(dashboard, ensure_ascii=False, indent=2) + '\n')
        print(name, '—', sum(p['type'] != 'row' for p in dashboard['panels']), 'панелей')
