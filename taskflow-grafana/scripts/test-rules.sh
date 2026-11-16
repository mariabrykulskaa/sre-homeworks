#!/usr/bin/env bash
# Юнит-тесты правил SLO: vmalert-tool прогоняет k8s/monitoring/rules/slo-rules.yaml
# на синтетических рядах (k8s/monitoring/rules/tests/*.test.yaml) и сверяет
# записанные значения и алерты с ожидаемыми. Кластер не нужен — только docker.
#
# Сценарии: норма, 5 % ошибок, медленные ответы, падение БД (slo-rules.test.yaml)
# и 450 минут простоя за окно — нарушение SLA (sla.test.yaml).
#
# Использование: scripts/test-rules.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

require_tools docker

RULES_DIR="$ROOT/k8s/monitoring/rules"
files=()
for f in "$RULES_DIR"/tests/*.test.yaml; do
  files+=(--files "$(basename "$f")")
done

# --disableAlertgroupLabel — как у vmalert в кластере (vmalert-values.yaml):
# без него у записанных рядов и алертов была бы лишняя метка alertgroup.
# Правила копируются в образ, а не монтируются томом: так тесты работают и с
# docker-демоном внутри minikube (eval $(minikube docker-env)), которому папки
# хоста не видны.
image="taskflow-rules-test:local"
printf 'FROM %s\nCOPY . /rules\nWORKDIR /rules/tests\n' "$VMALERT_TOOL_IMAGE" \
  | docker build -q -t "$image" -f - "$RULES_DIR" >/dev/null
docker run --rm "$image" unittest --disableAlertgroupLabel "${files[@]}"
