#!/usr/bin/env bash
set -euo pipefail

enabled="${PRUNE_ENABLED:-false}"
mode="${PRUNE_MODE:-dry-run}"
interval="${PRUNE_INTERVAL_SECONDS:-1800}"
start_delay="${PRUNE_START_DELAY_SECONDS:-900}"
sleep_pid=""

stop_scheduler() {
  if [[ -n "${sleep_pid}" ]]; then
    kill "${sleep_pid}" 2>/dev/null || true
  fi
  echo "Pruning scheduler stopped"
  exit 0
}

wait_for_next_run() {
  sleep "$1" &
  sleep_pid=$!
  wait "${sleep_pid}"
  sleep_pid=""
}

trap stop_scheduler TERM INT

case "${enabled,,}" in
  true|false) ;;
  *) echo "PRUNE_ENABLED must be true or false" >&2; exit 2 ;;
esac

case "${mode}" in
  dry-run) prune_argument=--dry-run ;;
  apply) prune_argument=--apply ;;
  *) echo "PRUNE_MODE must be dry-run or apply" >&2; exit 2 ;;
esac

[[ "${interval}" =~ ^[0-9]+$ ]] \
  || { echo "PRUNE_INTERVAL_SECONDS must be a non-negative integer" >&2; exit 2; }
[[ "${start_delay}" =~ ^[0-9]+$ ]] \
  || { echo "PRUNE_START_DELAY_SECONDS must be a non-negative integer" >&2; exit 2; }
(( interval >= 60 )) \
  || { echo "PRUNE_INTERVAL_SECONDS must be at least 60" >&2; exit 2; }

date +%s > /tmp/pruner-started-epoch
touch /tmp/pruner-scheduler-ready

if [[ "${enabled,,}" == "false" ]]; then
  echo "Pruning scheduler is disabled; set PRUNE_ENABLED=true after approving retention settings."
  while true; do wait_for_next_run "${interval}"; done
fi

echo "Pruning scheduler enabled mode=${mode} start_delay_seconds=${start_delay} interval_seconds=${interval}"
wait_for_next_run "${start_delay}"

while true; do
  if /usr/local/bin/prune.sh "${prune_argument}"; then
    date +%s > /tmp/pruner-last-success-epoch
  else
    echo "Prune run failed; scheduler will retry after the configured interval" >&2
  fi
  wait_for_next_run "${interval}"
done
