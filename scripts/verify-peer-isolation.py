#!/usr/bin/env python3
"""Verify that the running node uses only configured Quicknode peers."""

import argparse
import ipaddress
import json
import re
import subprocess
from pathlib import Path


IP_PATTERN = r"(?:\d{1,3}\.){3}\d{1,3}"
PEER_PORTS = {4001, 4002}


class IsolationError(RuntimeError):
    """A peer-isolation assertion failed without exposing an address."""


def fail(message: str) -> None:
    raise SystemExit(f"Peer isolation failed: {message}; addresses not printed")


def completed(command: list[str], project_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=project_dir,
        check=False,
        capture_output=True,
        text=True,
    )


def configured_peers(config: dict) -> tuple[set[str], set[str]]:
    try:
        roots = {item["Ip"] for item in config["root_node_ips"]}
        reserved = set(config["reserved_peer_ips"])
    except (KeyError, TypeError):
        raise IsolationError("active configuration has an unexpected peer schema") from None

    if config.get("try_new_peers") is not False:
        raise IsolationError("try_new_peers is not false")
    if len(roots) not in {1, 3}:
        raise IsolationError("expected one or three active roots")
    if not reserved:
        raise IsolationError("expected at least one reserved peer")
    return roots, reserved


def parse_ipv4_socket(hex_address: str) -> str | None:
    try:
        raw = bytes.fromhex(hex_address)
        if len(raw) != 4:
            return None
        return str(ipaddress.ip_address(raw[::-1]))
    except ValueError:
        return None


def parse_ipv6_socket(hex_address: str) -> str | None:
    try:
        raw = bytes.fromhex(hex_address)
        if len(raw) != 16:
            return None
        # Linux renders each 32-bit word in host byte order in /proc/net/tcp6.
        network_order = b"".join(raw[offset : offset + 4][::-1] for offset in range(0, 16, 4))
        address = ipaddress.ip_address(network_order)
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            return str(address.ipv4_mapped)
        return None
    except ValueError:
        return None


def established_peer_addresses(tcp: str, tcp6: str = "") -> set[str]:
    peers: set[str] = set()
    for table, parser in ((tcp, parse_ipv4_socket), (tcp6, parse_ipv6_socket)):
        for line in table.splitlines()[1:]:
            fields = line.split()
            if len(fields) < 4 or fields[3] != "01":
                continue
            try:
                address_hex, port_hex = fields[2].split(":", 1)
                port = int(port_hex, 16)
            except ValueError:
                continue
            if port not in PEER_PORTS:
                continue
            address = parser(address_hex)
            if address is not None:
                peers.add(address)
    return peers


def log_addresses(logs: str, pattern: str) -> list[str]:
    return re.findall(pattern, logs)


def evaluate_isolation(
    config: dict,
    logs: str,
    established_peers: set[str],
) -> dict[str, int | str]:
    roots, reserved = configured_peers(config)
    allowed = roots | reserved

    targets = log_addresses(logs, rf"connecting to peer: Ip\(({IP_PATTERN})\)")
    abci_sockets = log_addresses(logs, rf"connected to abci stream from ({IP_PATTERN}):")
    candidate_lines = [line for line in logs.splitlines() if "new candidate peers:" in line]
    candidates: list[str] = []
    for line in candidate_lines:
        candidates.extend(re.findall(rf"Ip\(({IP_PATTERN})\)", line))

    for label, values in (
        ("connection target", targets),
        ("ABCI socket", abci_sockets),
        ("candidate", candidates),
        ("established peer", established_peers),
    ):
        if set(values) - allowed:
            raise IsolationError(f"unexpected {label} detected")

    if candidates:
        raise IsolationError("candidate discovery occurred while try_new_peers was false")

    recent_peers = set(targets) | set(abci_sockets)
    connection_evidence = established_peers or recent_peers
    if not connection_evidence:
        raise IsolationError("no current or recent approved peer connection was observed")

    if len(roots) == 1 and connection_evidence != roots:
        raise IsolationError("isolated root was not the exclusive peer connection")

    status_lines = [line for line in logs.splitlines() if "got statuses" in line]
    status_ips: set[str] = set()
    if status_lines:
        status_ips = set(re.findall(rf"Ip\(({IP_PATTERN})\)", status_lines[-1]))
        if status_ips != roots:
            raise IsolationError("latest status response set does not match active roots")
        root_evidence = "status-response"
    elif established_peers:
        root_evidence = "established-sockets"
    else:
        root_evidence = "recent-socket-logs"

    return {
        "active_roots": len(roots),
        "reserved_peers": len(reserved),
        "status_roots": len(status_ips),
        "unique_target_peers": len(set(targets)),
        "target_events": len(targets),
        "abci_events": len(abci_sockets),
        "active_peer_connections": len(established_peers),
        "root_evidence": root_evidence,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--since",
        default="30m",
        help="Current-container log lookback used to reject unexpected activity (default: 30m)",
    )
    args = parser.parse_args()

    project_dir = Path(__file__).resolve().parent.parent
    container_result = completed(["docker", "compose", "ps", "-q", "node"], project_dir)
    container_id = container_result.stdout.strip()
    if container_result.returncode != 0 or not container_id:
        fail("running node container does not exist")

    config_result = completed(
        [
            "docker",
            "exec",
            container_id,
            "cat",
            "/home/hluser/override_gossip_config.json",
        ],
        project_dir,
    )
    if config_result.returncode != 0:
        fail("could not read the running node configuration")
    try:
        config = json.loads(config_result.stdout)
    except json.JSONDecodeError:
        fail("running node configuration is not valid JSON")

    logs_result = completed(
        ["docker", "logs", "--since", args.since, container_id],
        project_dir,
    )
    if logs_result.returncode != 0:
        fail("could not read current node-container logs")
    logs = logs_result.stdout + logs_result.stderr

    socket_tables: list[str] = []
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        result = completed(["docker", "exec", container_id, "cat", table], project_dir)
        if result.returncode != 0:
            fail("could not inspect current node sockets")
        socket_tables.append(result.stdout)

    try:
        stats = evaluate_isolation(
            config,
            logs,
            established_peer_addresses(*socket_tables),
        )
    except IsolationError as error:
        fail(str(error))

    print(
        "Peer isolation passed: "
        f"active_roots={stats['active_roots']} "
        f"reserved_peers={stats['reserved_peers']} "
        f"status_roots={stats['status_roots']} "
        f"unique_target_peers={stats['unique_target_peers']} "
        f"target_events={stats['target_events']} "
        f"abci_events={stats['abci_events']} "
        f"active_peer_connections={stats['active_peer_connections']} "
        f"root_evidence={stats['root_evidence']} "
        "candidate_events=0 unexpected=0; addresses not printed."
    )


if __name__ == "__main__":
    main()
