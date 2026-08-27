import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "verify-peer-isolation.py"
SPEC = importlib.util.spec_from_file_location("verify_peer_isolation", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


ROOTS = {"192.0.2.10", "192.0.2.11", "192.0.2.12"}
RESERVED = {"198.51.100.10", "198.51.100.11", "198.51.100.12"}


def config(roots=ROOTS):
    return {
        "root_node_ips": [{"Ip": address} for address in sorted(roots)],
        "reserved_peer_ips": sorted(RESERVED),
        "try_new_peers": False,
    }


class EvaluateIsolationTests(unittest.TestCase):
    def test_stable_established_peer_passes_without_startup_marker_or_recent_logs(self):
        stats = MODULE.evaluate_isolation(config(), "", {"192.0.2.10"})
        self.assertEqual(stats["root_evidence"], "established-sockets")
        self.assertEqual(stats["active_peer_connections"], 1)

    def test_status_response_allows_one_live_approved_socket(self):
        logs = (
            "got statuses: [Ip(192.0.2.10), Ip(192.0.2.11), Ip(192.0.2.12)]\n"
            "connecting to peer: Ip(192.0.2.10)\n"
            "connected to abci stream from 192.0.2.10:4001\n"
        )
        stats = MODULE.evaluate_isolation(config(), logs, {"192.0.2.10"})
        self.assertEqual(stats["root_evidence"], "status-response")
        self.assertEqual(stats["status_roots"], 3)

    def test_unexpected_logged_target_fails(self):
        with self.assertRaisesRegex(MODULE.IsolationError, "unexpected connection target"):
            MODULE.evaluate_isolation(
                config(),
                "connecting to peer: Ip(203.0.113.99)\n",
                {"192.0.2.10"},
            )

    def test_unexpected_established_peer_fails(self):
        with self.assertRaisesRegex(MODULE.IsolationError, "unexpected established peer"):
            MODULE.evaluate_isolation(config(), "", {"203.0.113.99"})

    def test_candidate_discovery_fails_even_for_configured_peer(self):
        logs = "new candidate peers: [Ip(192.0.2.10)]\n"
        with self.assertRaisesRegex(MODULE.IsolationError, "candidate discovery"):
            MODULE.evaluate_isolation(config(), logs, {"192.0.2.10"})

    def test_no_connection_evidence_fails(self):
        with self.assertRaisesRegex(MODULE.IsolationError, "no current or recent"):
            MODULE.evaluate_isolation(config(), "", set())

    def test_mismatched_status_response_fails(self):
        logs = "got statuses: [Ip(192.0.2.10)]\n"
        with self.assertRaisesRegex(MODULE.IsolationError, "status response set"):
            MODULE.evaluate_isolation(config(), logs, {"192.0.2.10"})

    def test_single_root_mode_remains_exclusive(self):
        single = {"192.0.2.10"}
        MODULE.evaluate_isolation(config(single), "", single)
        with self.assertRaisesRegex(MODULE.IsolationError, "isolated root"):
            MODULE.evaluate_isolation(config(single), "", {"198.51.100.10"})


class ProcSocketTests(unittest.TestCase):
    def test_extracts_only_established_peer_ports(self):
        tcp = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:9C41 0A0200C0:0FA1 01 00000000:00000000 00:00000000 00000000 10000 0 1
   1: 0100007F:9C42 0B0200C0:0FA2 01 00000000:00000000 00:00000000 00000000 10000 0 2
   2: 0100007F:9C43 0C0200C0:0FA1 06 00000000:00000000 00:00000000 00000000 10000 0 3
   3: 0100007F:9C44 0D0200C0:0016 01 00000000:00000000 00:00000000 00000000 10000 0 4
"""
        self.assertEqual(
            MODULE.established_peer_addresses(tcp),
            {"192.0.2.10", "192.0.2.11"},
        )

    def test_extracts_ipv4_mapped_tcp6_peer(self):
        tcp6 = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0000000000000000FFFF00000100007F:9C41 0000000000000000FFFF00000A0200C0:0FA1 01 00000000:00000000 00:00000000 00000000 10000 0 1
"""
        self.assertEqual(
            MODULE.established_peer_addresses("", tcp6),
            {"192.0.2.10"},
        )


if __name__ == "__main__":
    unittest.main()
