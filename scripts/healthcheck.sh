#!/usr/bin/env bash
set -euo pipefail

HL_HOME=/home/hluser/hl
DATA_ROOT="${HL_HOME}/data"
OUTPUT_OBSERVED_MARKER="${HL_HOME}/.replica-output-observed"
MIN_FREE_PERCENT="${MIN_FREE_PERCENT:-20}"
OUTPUT_STALE_MINUTES="${OUTPUT_STALE_MINUTES:-5}"
REQUIRE_MEMPOOL="${REQUIRE_MEMPOOL:-false}"

for value in "${MIN_FREE_PERCENT}" "${OUTPUT_STALE_MINUTES}"; do
  [[ "${value}" =~ ^[0-9]+$ ]] || exit 2
done
(( MIN_FREE_PERCENT >= 1 && MIN_FREE_PERCENT <= 99 )) || exit 2
(( OUTPUT_STALE_MINUTES >= 1 )) || exit 2

pgrep -x hl-visor >/dev/null
pgrep -x hl-node >/dev/null

used_percent="$(df -P "${HL_HOME}" | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
free_percent=$((100 - used_percent))
(( free_percent >= MIN_FREE_PERCENT )) || exit 1

# Visor writes its state file before initial state transfer finishes, so that
# file cannot distinguish bootstrap from a previously productive node. Until
# replica output has been observed, process liveness and disk headroom are the
# only valid Docker health signals. Once output exists, persist that fact and
# require it to remain fresh across container recreation.
if [[ ! -f "${OUTPUT_OBSERVED_MARKER}" ]]; then
  if ! find "${DATA_ROOT}/replica_cmds" -type f -print -quit 2>/dev/null | grep -q .; then
    exit 0
  fi
  install -m 0600 /dev/null "${OUTPUT_OBSERVED_MARKER}"
fi

find "${DATA_ROOT}/replica_cmds" -type f -mmin "-${OUTPUT_STALE_MINUTES}" -print -quit 2>/dev/null \
  | grep -q .

if [[ "${REQUIRE_MEMPOOL,,}" == "true" ]]; then
  find "${DATA_ROOT}/mempool_txs" -type f -mmin "-${OUTPUT_STALE_MINUTES}" -print -quit 2>/dev/null \
    | grep -q .
elif [[ "${REQUIRE_MEMPOOL,,}" != "false" ]]; then
  exit 2
fi
