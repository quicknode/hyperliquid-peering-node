#!/usr/bin/env bash
set -euo pipefail

CONFIG_SOURCE=/run/hyperliquid-config
HL_HOME=/home/hluser

required_files=(
  visor.json
  override_gossip_config.json
  override_public_ip_address
  node_gossip_priority_config.json
)

for file in "${required_files[@]}"; do
  if [[ ! -s "${CONFIG_SOURCE}/${file}" ]]; then
    echo "Missing required runtime configuration: ${file}" >&2
    exit 1
  fi
done

if [[ ! -f "${CONFIG_SOURCE}/node_output_flags" ]]; then
  echo "Missing required runtime configuration: node_output_flags" >&2
  exit 1
fi

install -d -m 0700 -o "${HL_USER_UID}" -g "${HL_USER_GID}" \
  "${HL_HOME}/hl" \
  "${HL_HOME}/hl/data" \
  "${HL_HOME}/hl/file_mod_time_tracker"

install -m 0600 -o "${HL_USER_UID}" -g "${HL_USER_GID}" \
  /dev/null "${HL_HOME}/hl/.hyperliquid-peering-volume"

install -m 0600 -o "${HL_USER_UID}" -g "${HL_USER_GID}" \
  "${CONFIG_SOURCE}/visor.json" \
  "${HL_HOME}/visor.json"
install -m 0600 -o "${HL_USER_UID}" -g "${HL_USER_GID}" \
  "${CONFIG_SOURCE}/override_gossip_config.json" \
  "${HL_HOME}/override_gossip_config.json"
install -m 0600 -o "${HL_USER_UID}" -g "${HL_USER_GID}" \
  "${CONFIG_SOURCE}/override_public_ip_address" \
  "${HL_HOME}/hl/override_public_ip_address"
install -m 0600 -o "${HL_USER_UID}" -g "${HL_USER_GID}" \
  "${CONFIG_SOURCE}/node_gossip_priority_config.json" \
  "${HL_HOME}/hl/file_mod_time_tracker/node_gossip_priority_config.json"

mapfile -t node_output_args < "${CONFIG_SOURCE}/node_output_flags"

exec setpriv \
  --reuid="${HL_USER_UID}" \
  --regid="${HL_USER_GID}" \
  --init-groups \
  "$@" \
  "${node_output_args[@]}"
