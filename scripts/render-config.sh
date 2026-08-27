#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE-${PROJECT_DIR}/.env}"
RUNTIME_DIR="${RUNTIME_DIR:-${PROJECT_DIR}/runtime}"

if [[ -n "${ENV_FILE}" ]]; then
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing ${ENV_FILE}. Copy .env.example to .env and configure it." >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
elif [[ -z "${PEER_MODE:-}" ]]; then
  echo "PEER_MODE is missing from the environment" >&2
  exit 1
fi

export PEER_MODE="${PEER_MODE:-quicknode}"
export TRY_NEW_PEERS="${TRY_NEW_PEERS:-false}"
export SPLIT_CLIENT_BLOCKS="${SPLIT_CLIENT_BLOCKS:-true}"
export ENABLE_PRIORITY_ORDERING="${ENABLE_PRIORITY_ORDERING:-false}"
export NODE_OUTPUT_FLAGS="${NODE_OUTPUT_FLAGS:-}"

umask 077
mkdir -p "${RUNTIME_DIR}"

python3 - "${RUNTIME_DIR}" <<'PY'
import ipaddress
import concurrent.futures
import json
import os
import pathlib
import socket
import urllib.request
import sys

runtime_dir = pathlib.Path(sys.argv[1])


def parse_bool(name: str) -> bool:
    value = os.environ[name].strip().lower()
    if value not in {"true", "false"}:
        raise SystemExit(f"{name} must be true or false")
    return value == "true"


def parse_ipv4(name: str, value: str) -> str:
    try:
        address = ipaddress.ip_address(value.strip())
    except ValueError as exc:
        raise SystemExit(f"{name} must be a valid IPv4 address") from exc
    if address.version != 4:
        raise SystemExit(f"{name} must be an IPv4 address")
    if not address.is_global:
        raise SystemExit(f"{name} must be a globally routable IPv4 address, not a placeholder or private address")
    return str(address)


def parse_ipv4_list(name: str, value: str, *, require_values: bool = True) -> list[str]:
    values = [item.strip() for item in value.split(",") if item.strip()]
    if require_values and not values:
        raise SystemExit(f"{name} must contain at least one IPv4 address")
    addresses = [parse_ipv4(f"{name} entry", item) for item in values]
    if len(set(addresses)) != len(addresses):
        raise SystemExit(f"{name} entries must be distinct")
    return addresses


allowed_node_output_flags = {
    "--write-trades",
    "--write-fills",
    "--write-order-statuses",
    "--write-raw-book-diffs",
    "--write-hip3-oracle-updates",
    "--write-misc-events",
    "--write-system-and-core-writer-actions",
    "--batch-by-block",
    "--stream-with-block-info",
}
node_output_flags = os.environ["NODE_OUTPUT_FLAGS"].split()
unknown_node_output_flags = sorted(set(node_output_flags) - allowed_node_output_flags)
if unknown_node_output_flags:
    raise SystemExit(
        "NODE_OUTPUT_FLAGS contains unsupported value(s): "
        + ", ".join(unknown_node_output_flags)
    )
if len(set(node_output_flags)) != len(node_output_flags):
    raise SystemExit("NODE_OUTPUT_FLAGS must not contain duplicate values")


mode = os.environ["PEER_MODE"].strip().lower()
public_ip = parse_ipv4("PUBLIC_IP", os.environ.get("PUBLIC_IP", ""))

if mode == "quicknode":
    configured_peers = parse_ipv4_list(
        "QUICKNODE_ROOT_NODE_IPS", os.environ.get("QUICKNODE_ROOT_NODE_IPS", "")
    )
    if len(configured_peers) != 3:
        raise SystemExit("QUICKNODE_ROOT_NODE_IPS must contain exactly three addresses")
    reserved_peers = parse_ipv4_list(
        "QUICKNODE_RESERVED_PEER_IPS",
        os.environ.get("QUICKNODE_RESERVED_PEER_IPS", ""),
    )
    active_roots = os.environ.get("QUICKNODE_ACTIVE_ROOTS", "all").strip().lower()
    if active_roots == "all":
        peers = configured_peers
    elif active_roots in {"1", "2", "3"}:
        peers = [configured_peers[int(active_roots) - 1]]
    else:
        raise SystemExit("QUICKNODE_ACTIVE_ROOTS must be all, 1, 2, or 3")
    try_new_peers = parse_bool("TRY_NEW_PEERS")
    if try_new_peers:
        raise SystemExit("Quicknode mode requires TRY_NEW_PEERS=false for isolated validation")
elif mode == "public":
    request = urllib.request.Request(
        "https://api.hyperliquid.xyz/info",
        data=json.dumps({"type": "gossipRootIps"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = json.load(response)
    if not isinstance(payload, list) or not payload:
        raise SystemExit("gossipRootIps returned no peers")
    peers = [parse_ipv4("public root peer", value) for value in payload]
    peers = list(dict.fromkeys(peers))

    def accepts_abci_stream(peer: str) -> bool:
        try:
            with socket.create_connection((peer, 4001), timeout=2):
                return True
        except OSError:
            return False

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(32, len(peers))) as pool:
        reachability = list(pool.map(accepts_abci_stream, peers))
    peers = [peer for peer, reachable in zip(peers, reachability) if reachable]
    if not peers:
        raise SystemExit("No public root peer accepted a TCP connection on port 4001")
    try_new_peers = True
    reserved_peers = []
else:
    raise SystemExit("PEER_MODE must be quicknode or public")

gossip_config = {
    "root_node_ips": [{"Ip": peer} for peer in peers],
    "try_new_peers": try_new_peers,
    "chain": "Mainnet",
    "reserved_peer_ips": reserved_peers,
    "split_client_blocks": parse_bool("SPLIT_CLIENT_BLOCKS"),
}

(runtime_dir / "visor.json").write_text(
    json.dumps({"chain": "Mainnet"}, indent=2) + "\n"
)
(runtime_dir / "override_gossip_config.json").write_text(
    json.dumps(gossip_config, indent=2) + "\n"
)
(runtime_dir / "node_gossip_priority_config.json").write_text(
    json.dumps({"enabled": parse_bool("ENABLE_PRIORITY_ORDERING")}, indent=2) + "\n"
)
(runtime_dir / "node_output_flags").write_text(
    "\n".join(node_output_flags) + ("\n" if node_output_flags else "")
)
(runtime_dir / "override_public_ip_address").write_text(public_ip + "\n")

print(
    f"Rendered Mainnet configuration for {mode} mode with {len(peers)} active root(s) "
    f"and {len(reserved_peers)} reserved peer(s); "
    f"node_output_flags={len(node_output_flags)}; peer addresses were not printed."
)
PY
