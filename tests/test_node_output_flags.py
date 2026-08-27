import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
RENDER_CONFIG = REPOSITORY_ROOT / "scripts" / "render-config.sh"
COMPOSE_FILE = REPOSITORY_ROOT / "docker-compose.yml"


class NodeOutputFlagsTests(unittest.TestCase):
    def render(
        self, node_output_flags: str
    ) -> tuple[subprocess.CompletedProcess[str], str | None]:
        with tempfile.TemporaryDirectory() as runtime_dir:
            environment = os.environ.copy()
            environment.update(
                {
                    "ENV_FILE": "",
                    "RUNTIME_DIR": runtime_dir,
                    "PEER_MODE": "quicknode",
                    "PUBLIC_IP": "8.8.8.8",
                    "QUICKNODE_ROOT_NODE_IPS": "1.1.1.1,8.8.4.4,9.9.9.9",
                    "QUICKNODE_RESERVED_PEER_IPS": (
                        "208.67.222.222,208.67.220.220,4.2.2.1"
                    ),
                    "QUICKNODE_ACTIVE_ROOTS": "all",
                    "TRY_NEW_PEERS": "false",
                    "SPLIT_CLIENT_BLOCKS": "true",
                    "ENABLE_PRIORITY_ORDERING": "false",
                    "NODE_OUTPUT_FLAGS": node_output_flags,
                }
            )
            result = subprocess.run(
                [str(RENDER_CONFIG)],
                cwd=REPOSITORY_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            flags_path = Path(runtime_dir) / "node_output_flags"
            rendered_flags = flags_path.read_text() if flags_path.exists() else None
            return result, rendered_flags

    def test_accepts_documented_file_output_flags(self):
        flags = " ".join(
            [
                "--write-trades",
                "--write-fills",
                "--write-order-statuses",
                "--write-raw-book-diffs",
                "--write-hip3-oracle-updates",
                "--write-misc-events",
                "--write-system-and-core-writer-actions",
                "--batch-by-block",
                "--stream-with-block-info",
            ]
        )

        result, rendered_flags = self.render(flags)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("node_output_flags=9", result.stdout)
        self.assertEqual(rendered_flags, flags.replace(" ", "\n") + "\n")

    def test_empty_value_renders_empty_argument_file(self):
        result, rendered_flags = self.render("")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered_flags, "")

    def test_node_does_not_receive_unvalidated_flag_environment(self):
        compose = COMPOSE_FILE.read_text()
        node_service = compose.split("\n  node:\n", 1)[1].split("\n  pruner:\n", 1)[0]

        self.assertNotIn("NODE_OUTPUT_FLAGS:", node_service)

    def test_rejects_unknown_flag(self):
        result, rendered_flags = self.render("--serve-eth-rpc")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported value", result.stderr)
        self.assertIsNone(rendered_flags)

    def test_rejects_duplicate_flag(self):
        result, rendered_flags = self.render("--write-fills --write-fills")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not contain duplicate values", result.stderr)
        self.assertIsNone(rendered_flags)


if __name__ == "__main__":
    unittest.main()
