#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

if [[ ! -f .env ]]; then
  echo "Missing ${PROJECT_DIR}/.env. Copy .env.example to .env and configure it." >&2
  exit 2
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

OUTPUT_STALE_MINUTES="${OUTPUT_STALE_MINUTES:-5}"
MIN_FREE_PERCENT="${MIN_FREE_PERCENT:-20}"
REQUIRE_MEMPOOL="${REQUIRE_MEMPOOL:-false}"

config_id="$(docker compose ps -a -q config)"
[[ -n "${config_id}" ]] || { echo "Configuration container does not exist" >&2; exit 1; }
[[ "$(docker inspect --format '{{.State.Status}}' "${config_id}")" == "exited" ]] \
  || { echo "Configuration container has not completed" >&2; exit 1; }
[[ "$(docker inspect --format '{{.State.ExitCode}}' "${config_id}")" == "0" ]] \
  || { echo "Configuration container did not validate successfully" >&2; exit 1; }

container_id="$(docker compose ps -q node)"
[[ -n "${container_id}" ]] || { echo "Node container does not exist" >&2; exit 1; }
[[ "$(docker inspect --format '{{.State.Running}}' "${container_id}")" == "true" ]] \
  || { echo "Node container is not running" >&2; exit 1; }

restart_count="$(docker inspect --format '{{.RestartCount}}' "${container_id}")"
health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container_id}")"
[[ "${health}" == "healthy" ]] \
  || { echo "Node container health is ${health}, expected healthy" >&2; exit 1; }

docker compose exec -T \
  -e RUNTIME_DIR=/run/hyperliquid-config \
  node /usr/local/bin/verify-config.sh

used_percent="$(df -P . | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
free_percent=$((100 - used_percent))
(( free_percent >= MIN_FREE_PERCENT )) \
  || { echo "Disk free space is below ${MIN_FREE_PERCENT}%" >&2; exit 1; }

started_at="$(docker inspect --format '{{.State.StartedAt}}' "${container_id}")"
started_epoch="$(date --date="${started_at}" +%s)"
window_epoch="$(date --date="-${OUTPUT_STALE_MINUTES} minutes" +%s)"
if (( started_epoch > window_epoch )); then
  log_since_epoch="${started_epoch}"
else
  log_since_epoch="${window_epoch}"
fi
log_since="$(date --utc --date="@${log_since_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
recent_logs="$(docker compose logs --no-color --since "${log_since}" node 2>&1)"
mapfile -t heights < <(grep -oE 'applied block [0-9]+' <<<"${recent_logs}" | awk '{print $3}' | tail -n 20)
if (( ${#heights[@]} < 2 )); then
  echo "Fewer than two applied-block signals appeared in the freshness window" >&2
  exit 1
fi
if (( heights[${#heights[@]}-1] <= heights[0] )); then
  echo "Applied block height did not advance" >&2
  exit 1
fi

docker compose exec -T node sh -c \
  "find /home/hluser/hl/data/replica_cmds -type f -mmin -${OUTPUT_STALE_MINUTES} -print -quit" \
  | grep -q . \
  || { echo "Replica output is stale or missing" >&2; exit 1; }

if [[ "${REQUIRE_MEMPOOL,,}" == "true" ]]; then
  docker compose exec -T node sh -c \
    "find /home/hluser/hl/data/mempool_txs -type f -mmin -${OUTPUT_STALE_MINUTES} -print -quit" \
    | grep -q . \
    || { echo "Mempool output is stale or missing" >&2; exit 1; }
elif [[ "${REQUIRE_MEMPOOL,,}" != "false" ]]; then
  echo "REQUIRE_MEMPOOL must be true or false" >&2
  exit 2
fi

echo "Verification passed: configuration valid; container running; health=${health}; restarts=${restart_count}; applied height advanced; outputs fresh; disk free=${free_percent}%. Addresses not printed."
