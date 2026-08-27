#!/usr/bin/env bash
set -euo pipefail

[[ -f /tmp/pruner-scheduler-ready ]]

enabled="${PRUNE_ENABLED:-false}"
[[ "${enabled,,}" == "true" ]] || exit 0

interval="${PRUNE_INTERVAL_SECONDS:-1800}"
start_delay="${PRUNE_START_DELAY_SECONDS:-900}"
grace_seconds=300
now="$(date +%s)"
started="$(cat /tmp/pruner-started-epoch)"

if (( now - started <= start_delay + grace_seconds )); then
  exit 0
fi

[[ -f /tmp/pruner-last-success-epoch ]]
last_success="$(cat /tmp/pruner-last-success-epoch)"
(( now - last_success <= interval + grace_seconds ))
