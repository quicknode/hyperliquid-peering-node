#!/usr/bin/env bash
set -euo pipefail

[[ "${EUID}" -eq 0 ]] || { echo "Run as root on the dedicated test host" >&2; exit 2; }
[[ "${CONFIRM_UNAVAILABLE_PEER_TEST:-}" == "yes" ]] \
  || { echo "Set CONFIRM_UNAVAILABLE_PEER_TEST=yes to run this disruptive validation" >&2; exit 2; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

selector="$(awk -F= '$1 == "QUICKNODE_ACTIVE_ROOTS" {value=$2} END {print value}' .env)"
[[ "${selector}" == "all" ]] \
  || { echo "The test requires QUICKNODE_ACTIVE_ROOTS=all" >&2; exit 2; }
docker compose exec -T \
  -e RUNTIME_DIR=/run/hyperliquid-config \
  node /usr/local/bin/verify-config.sh

container_id="$(docker compose ps -q node)"
[[ -n "${container_id}" ]] || { echo "Node container not found" >&2; exit 2; }
container_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_id}")"
[[ "${container_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
  || { echo "Could not resolve the node container IPv4 address" >&2; exit 2; }

outbound_added=false
inbound_added=false
cleanup_done=false

cleanup() {
  [[ "${cleanup_done}" == "false" ]] || return 0
  cleanup_done=true
  set +e
  if [[ "${outbound_added}" == "true" ]]; then
    iptables -D DOCKER-USER -s "${container_ip}" -p tcp -m multiport --dports 4001,4002 \
      -m comment --comment hl-unavailable-peer-outbound -j REJECT
  fi
  if [[ "${inbound_added}" == "true" ]]; then
    iptables -D DOCKER-USER -d "${container_ip}" -p tcp -m multiport --dports 4001,4002 \
      -m comment --comment hl-unavailable-peer-inbound -j REJECT
  fi
  docker compose restart node
}
trap cleanup EXIT INT TERM

for comment in hl-unavailable-peer-outbound hl-unavailable-peer-inbound; do
  iptables -S DOCKER-USER | grep -q -- "--comment ${comment}" \
    && { echo "Test firewall rule already exists" >&2; exit 2; }
done

iptables -I DOCKER-USER 1 -s "${container_ip}" -p tcp -m multiport --dports 4001,4002 \
  -m comment --comment hl-unavailable-peer-outbound -j REJECT
outbound_added=true
iptables -I DOCKER-USER 1 -d "${container_ip}" -p tcp -m multiport --dports 4001,4002 \
  -m comment --comment hl-unavailable-peer-inbound -j REJECT
inbound_added=true

docker compose restart node
observation_epoch="$(date +%s)"
sleep "${UNAVAILABLE_OBSERVATION_SECONDS:-45}"

OBSERVATION_EPOCH="${observation_epoch}" python3 - <<'PY'
import json
import os
import re
import subprocess
from pathlib import Path

observation = int(os.environ["OBSERVATION_EPOCH"])
since = subprocess.run(
    ["date", "-u", "-d", f"@{observation}", "+%Y-%m-%dT%H:%M:%SZ"],
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()
logs_result = subprocess.run(
    ["docker", "compose", "logs", "--no-color", "--since", since, "node"],
    check=True,
    capture_output=True,
    text=True,
)
logs = logs_result.stdout + logs_result.stderr
config_result = subprocess.run(
    [
        "docker",
        "compose",
        "exec",
        "-T",
        "node",
        "cat",
        "/run/hyperliquid-config/override_gossip_config.json",
    ],
    check=True,
    capture_output=True,
    text=True,
)
config = json.loads(config_result.stdout)
roots = {item["Ip"] for item in config["root_node_ips"]}

status_queries = re.findall(r"querying status.*?rpc_ip: Ip\(((?:\d{1,3}\.){3}\d{1,3})\)", logs)
connect_targets = re.findall(r"connecting to peer: Ip\(((?:\d{1,3}\.){3}\d{1,3})\)", logs)
attempted = status_queries + connect_targets
abci_sockets = re.findall(r"connected to abci stream from ((?:\d{1,3}\.){3}\d{1,3}):", logs)
applied = re.findall(r"applied block (\d+)", logs)
candidate_lines = [line for line in logs.splitlines() if "new candidate peers:" in line]
diagnostics = sum(
    logs.count(text)
    for text in (
        "unable to query status",
        "no status from node",
        "timed out",
        "Connection refused",
        "connection refused",
        "Network is unreachable",
    )
)

volume = subprocess.run(
    ["docker", "volume", "inspect", "hyperliquid-peering_hl-home", "--format", "{{.Mountpoint}}"],
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()
data_root = Path(volume) / "data"

def post_cutover_files(name: str) -> int:
    directory = data_root / name
    if not directory.exists():
        return 0
    return sum(1 for path in directory.rglob("*") if path.is_file() and path.stat().st_mtime > observation)

replica_files = post_cutover_files("replica_cmds")
mempool_files = post_cutover_files("mempool_txs")

if not attempted or set(attempted) - roots:
    raise SystemExit("Unavailable-peer test did not target only configured roots; addresses not printed")
if abci_sockets or applied or candidate_lines or replica_files or mempool_files:
    raise SystemExit("Unavailable-peer failure was masked by another data source; addresses not printed")
if diagnostics == 0:
    raise SystemExit("Unavailable-peer diagnostic was not observed; addresses not printed")

print(
    "Unavailable-peer-path test passed: "
    f"configured_attempts={len(attempted)} diagnostics={diagnostics} "
    "abci_sockets=0 applied_blocks=0 replica_files=0 mempool_files=0 "
    "candidate_events=0; addresses not printed."
)
PY

cleanup
trap - EXIT INT TERM
echo "Combined Quicknode configuration retained; peer networking restored; node restart requested."
