#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${RUNTIME_DIR:-${PROJECT_DIR}/runtime}"

python3 - "${RUNTIME_DIR}" <<'PY'
import ipaddress
import json
import pathlib
import sys

runtime_dir = pathlib.Path(sys.argv[1])
required = {
    "visor.json",
    "override_gossip_config.json",
    "override_public_ip_address",
    "node_gossip_priority_config.json",
}
missing = sorted(name for name in required if not (runtime_dir / name).is_file())
if missing:
    raise SystemExit(f"Missing rendered files: {', '.join(missing)}")

visor = json.loads((runtime_dir / "visor.json").read_text())
gossip = json.loads((runtime_dir / "override_gossip_config.json").read_text())
priority = json.loads((runtime_dir / "node_gossip_priority_config.json").read_text())
public_ip = (runtime_dir / "override_public_ip_address").read_text().strip()

if visor != {"chain": "Mainnet"}:
    raise SystemExit("visor.json is not the expected Mainnet configuration")
if gossip.get("chain") != "Mainnet":
    raise SystemExit("gossip configuration is not Mainnet")
if not isinstance(gossip.get("split_client_blocks"), bool):
    raise SystemExit("split_client_blocks must be boolean")
if not isinstance(gossip.get("try_new_peers"), bool):
    raise SystemExit("try_new_peers must be boolean")
reserved_peers = gossip.get("reserved_peer_ips")
if not isinstance(reserved_peers, list):
    raise SystemExit("reserved_peer_ips must be a list")
peers = gossip.get("root_node_ips")
if not isinstance(peers, list) or not peers:
    raise SystemExit("At least one root peer is required")
peer_addresses = []
for peer in peers:
    if set(peer) != {"Ip"}:
        raise SystemExit("Unexpected root_node_ips schema")
    address = ipaddress.ip_address(peer["Ip"])
    if address.version != 4:
        raise SystemExit("Root peers must be IPv4 addresses")
    if not address.is_global:
        raise SystemExit("Root peers must be globally routable, non-placeholder IPv4 addresses")
    peer_addresses.append(str(address))
if len(set(peer_addresses)) != len(peer_addresses):
    raise SystemExit("Root peer addresses must be distinct")
if gossip["try_new_peers"] is False and len(peer_addresses) not in {1, 3}:
    raise SystemExit("Isolated Quicknode configuration requires one or three active roots")
reserved_addresses = []
for peer in reserved_peers:
    if not isinstance(peer, str):
        raise SystemExit("Reserved peers must use the IPv4 string schema")
    address = ipaddress.ip_address(peer)
    if address.version != 4 or not address.is_global:
        raise SystemExit("Reserved peers must be globally routable, non-placeholder IPv4 addresses")
    reserved_addresses.append(str(address))
if len(set(reserved_addresses)) != len(reserved_addresses):
    raise SystemExit("Reserved peer addresses must be distinct")
if gossip["try_new_peers"] is False and not reserved_addresses:
    raise SystemExit("Isolated Quicknode configuration requires at least one reserved peer")
if gossip["try_new_peers"] is True and reserved_addresses:
    raise SystemExit("Public development configuration must not set reserved peers")
if set(priority) != {"enabled"} or not isinstance(priority["enabled"], bool):
    raise SystemExit("Unexpected priority configuration")
public_address = ipaddress.ip_address(public_ip)
if public_address.version != 4:
    raise SystemExit("Public node address must be IPv4")
if not public_address.is_global:
    raise SystemExit("Public node address must be globally routable and non-placeholder")

print(
    f"Configuration valid: Mainnet, {len(peers)} root peer(s), "
    f"try_new_peers={gossip['try_new_peers']}, "
    f"split_client_blocks={gossip['split_client_blocks']}, "
    f"reserved_peers={len(reserved_addresses)}, "
    f"priority_ordering={priority['enabled']}; addresses not printed."
)
PY
