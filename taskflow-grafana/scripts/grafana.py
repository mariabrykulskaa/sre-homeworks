#!/usr/bin/env python3
"""Import, export and verify dashboards against the actual running stack."""
import argparse
import base64
import datetime as dt
import json
import math
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GRAFANA = os.environ.get('GRAFANA_URL', 'http://127.0.0.1:3000').rstrip('/')
VM = os.environ.get('VM_URL', 'http://127.0.0.1:8428').rstrip('/')
FILES = ['taskflow-overview.json', 'postgresql-exporter.json']


def request(url, body=None, headers=None):
    if body is not None:
        body = json.dumps(body).encode()
    req = urllib.request.Request(url, data=body, headers={'Content-Type': 'application/json', **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'{req.method} {url}: {error.code} {error.read().decode()[:500]}') from error


def credentials():
    if os.environ.get('GRAFANA_PASSWORD'):
        return os.environ.get('GRAFANA_USER', 'admin'), os.environ['GRAFANA_PASSWORD']
    secret = json.loads(subprocess.check_output(['kubectl', '-n', 'monitoring', 'get', 'secret', 'grafana-admin', '-o', 'json']))['data']
    return tuple(base64.b64decode(secret[key]).decode() for key in ('admin-user', 'admin-password'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['import', 'export', 'verify', 'capture'])
    args = parser.parse_args()
    user, password = credentials()
    headers = {'Authorization': 'Basic ' + base64.b64encode(f'{user}:{password}'.encode()).decode()}
    def grafana(path, body=None):
        return request(GRAFANA + path, body, headers)

    evidence = ROOT / 'evidence'
    evidence.mkdir(exist_ok=True)
    if args.command == 'capture':
        env = {**os.environ, 'GRAFANA_USER': user, 'GRAFANA_PASSWORD': password}
        subprocess.run(['node', str(ROOT / 'scripts/capture.mjs')], env=env, check=True)
        return
    if args.command == 'import':
        folders = grafana('/api/folders')
        folder = next((f for f in folders if f['title'] == 'TaskFlow'), None)
        if not folder:
            folder = grafana('/api/folders', {'uid': 'taskflow', 'title': 'TaskFlow'})
        receipts = []
        for name in FILES:
            dashboard = json.loads((ROOT / 'k8s/monitoring/dashboards' / name).read_text())
            receipt = grafana('/api/dashboards/db', {'dashboard': dashboard, 'folderUid': folder['uid'],
                                                     'overwrite': True, 'message': 'Grafana homework: application, prober SLA and imported PostgreSQL 9628/r8'})
            receipts.append({'file': name, 'receipt': receipt})
            print('Импорт:', name, receipt['status'], receipt['url'])
        (evidence / 'dashboard-import.json').write_text(json.dumps(receipts, ensure_ascii=False, indent=2) + '\n')
    elif args.command == 'export':
        for uid, name in [('taskflow-overview', FILES[0]), ('taskflow-postgresql', FILES[1])]:
            dashboard = grafana('/api/dashboards/uid/' + uid)['dashboard']
            dashboard['id'] = None
            (ROOT / 'dashboards' / name).write_text(json.dumps(dashboard, ensure_ascii=False, indent=2) + '\n')
            print('Экспорт из Grafana:', name)
    else:
        datasource = grafana('/api/datasources/uid/victoriametrics')
        health = grafana('/api/datasources/uid/victoriametrics/health')
        with urllib.request.urlopen(VM + '/api/v1/query?' + urllib.parse.urlencode({'query': 'pg_up{job="postgres"}'}), timeout=30) as r:
            instance = json.load(r)['data']['result'][0]['metric']['instance']
        variables = {'$__rate_interval': '1m', '$__interval': '15s', '$__range': '1h',
                     '$pod': '.*', '$instance': instance, '$datname': 'taskflow', '$mode': '.*'}
        records, failures = [], []
        now = int(time.time() * 1000)
        for name in FILES:
            source = json.loads((ROOT / 'k8s/monitoring/dashboards' / name).read_text())
            live = grafana('/api/dashboards/uid/' + source['uid'])['dashboard']
            assert live['uid'] == source['uid']
            for panel in source['panels']:
                for target in panel.get('targets', []):
                    expr = target['expr']
                    for var, value in variables.items():
                        expr = expr.replace(var, value)
                    query = {**target, 'expr': expr, 'intervalMs': 15000, 'maxDataPoints': 240}
                    try:
                        data = grafana('/api/ds/query', {'queries': [query], 'from': str(now - 3600000), 'to': str(now)})['results'][target['refId']]
                        if data.get('error'):
                            raise RuntimeError(data['error'])
                        frames = data.get('frames', [])
                        # Numeric values, not the timestamps, must be present and finite.
                        values = []
                        for frame in frames:
                            for field, column in zip(frame['schema']['fields'], frame['data']['values']):
                                if field['type'] == 'number':
                                    values.extend(v for v in column if isinstance(v, (int, float)) and math.isfinite(v))
                        if not values:
                            raise RuntimeError('Нет конечных числовых значений')
                        records.append({'dashboard': source['uid'], 'panel': panel['id'], 'title': panel['title'],
                                        'refId': target['refId'], 'expr': expr, 'frames': len(frames),
                                        'numeric_points': len(values), 'last_value': values[-1], 'ok': True})
                    except Exception as error:
                        failures.append({'dashboard': source['uid'], 'panel': panel['id'], 'expr': expr, 'error': str(error)})
        report = {'checked_at': dt.datetime.now(dt.timezone.utc).isoformat(),
                  'grafana': grafana('/api/health'), 'datasource': datasource, 'datasource_health': health,
                  'successful_queries': len(records), 'failed_queries': len(failures),
                  'queries': records, 'failures': failures}
        (evidence / 'cluster-pods.txt').write_bytes(subprocess.check_output(['kubectl', 'get', 'pods', '-A']))
        deployment = json.loads(subprocess.check_output(['kubectl', '-n', 'monitoring', 'get', 'deployment', 'grafana', '-o', 'json']))
        configmap = json.loads(subprocess.check_output(['kubectl', '-n', 'monitoring', 'get', 'configmap', 'grafana-dashboards-slo', '-o', 'json']))
        provisioned = {name: json.loads(text)['uid'] for name, text in configmap['data'].items()}
        assert provisioned['taskflow-overview.json'] == 'taskflow-overview'
        assert provisioned['postgresql-exporter.json'] == 'taskflow-postgresql'
        report['provisioning'] = {
            'context': subprocess.check_output(['kubectl', 'config', 'current-context'], text=True).strip(),
            'namespace': deployment['metadata']['namespace'], 'deployment': deployment['metadata']['name'],
            'ready_replicas': deployment['status'].get('readyReplicas', 0),
            'images': [c['image'] for c in deployment['spec']['template']['spec']['containers']],
            'configmap': configmap['metadata']['name'], 'dashboards': provisioned,
        }
        (evidence / 'dashboard-queries.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print('Источник данных:', health)
        print(f'Запросов с данными через Grafana: {len(records)}, ошибок: {len(failures)}')
        for failure in failures:
            print(json.dumps(failure, ensure_ascii=False))
        if failures:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
