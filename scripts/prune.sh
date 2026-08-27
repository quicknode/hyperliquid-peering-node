#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="${DATA_ROOT:-/home/hluser/hl/data}"
VOLUME_MARKER=/home/hluser/hl/.hyperliquid-peering-volume
mode="${1:---dry-run}"

case "${mode}" in
  --dry-run) apply=false ;;
  --apply) apply=true ;;
  *) echo "Usage: prune.sh [--dry-run|--apply]" >&2; exit 2 ;;
esac

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(timestamp) $*"; }

resolved_root="$(readlink -f "${DATA_ROOT}")"
[[ "${resolved_root}" == "/home/hluser/hl/data" ]] \
  || { log "Refusing unexpected data root" >&2; exit 2; }
[[ -f "${VOLUME_MARKER}" ]] \
  || { log "Refusing unmarked volume" >&2; exit 2; }
[[ -d "${resolved_root}" ]] \
  || { log "Data root does not exist" >&2; exit 2; }
find "${resolved_root}" -mindepth 1 -print -quit | grep -q . \
  || { log "Refusing empty data root" >&2; exit 2; }

classes=(
  "mempool_txs:${MEMPOOL_RETENTION_MINUTES:-360}"
  "replica_cmds:${BLOCK_RETENTION_MINUTES:-1440}"
  "node_logs:${LOG_RETENTION_MINUTES:-1440}"
)

size_before="$(du -sb "${resolved_root}" | awk '{print $1}')"
files_before="$(find "${resolved_root}" -type f | wc -l)"
deleted_total=0
bytes_total=0

log "Prune started mode=${mode} bytes_before=${size_before} files_before=${files_before}"

for class_config in "${classes[@]}"; do
  class="${class_config%%:*}"
  retention_minutes="${class_config##*:}"
  [[ "${retention_minutes}" =~ ^[0-9]+$ ]] && (( retention_minutes >= 1 )) \
    || { log "Invalid retention for ${class}" >&2; exit 2; }

  target="${resolved_root}/${class}"
  [[ -d "${target}" ]] || { log "class=${class} status=absent"; continue; }
  [[ "$(readlink -f "${target}")" == "${resolved_root}/${class}" ]] \
    || { log "Refusing unexpected target for ${class}" >&2; exit 2; }

  mapfile -d '' candidates < <(
    find "${target}" -type f -mmin "+${retention_minutes}" -print0
  )
  class_bytes=0
  for file in "${candidates[@]}"; do
    file_bytes="$(stat -c %s "${file}")"
    class_bytes=$((class_bytes + file_bytes))
  done

  if [[ "${apply}" == "true" ]]; then
    log "class=${class} retention_minutes=${retention_minutes} deleting=${#candidates[@]} bytes=${class_bytes}"
  else
    log "class=${class} retention_minutes=${retention_minutes} candidates=${#candidates[@]} bytes=${class_bytes}"
  fi

  if [[ "${apply}" == "true" ]] && (( ${#candidates[@]} > 0 )); then
    for file in "${candidates[@]}"; do
      rm -- "${file}"
    done
    find "${target}" -depth -mindepth 1 -type d -empty -delete
  fi

  deleted_total=$((deleted_total + ${#candidates[@]}))
  bytes_total=$((bytes_total + class_bytes))
done

size_after="$(du -sb "${resolved_root}" | awk '{print $1}')"
files_after="$(find "${resolved_root}" -type f | wc -l)"
if [[ "${apply}" == "true" ]]; then
  log "Prune completed mode=${mode} deleted=${deleted_total} deleted_bytes=${bytes_total} bytes_after=${size_after} files_after=${files_after}"
else
  log "Prune completed mode=${mode} candidates=${deleted_total} candidate_bytes=${bytes_total} bytes_after=${size_after} files_after=${files_after}"
fi
