# Contributing

Contributions that improve the deployment, diagnostics, or documentation are welcome.

## Before opening a pull request

1. Do not commit a real public node address, Quicknode peer address, endpoint, credential, `.env` file, rendered configuration, or captured node output.
2. Keep Docker Compose as the supported deployment path.
3. Preserve the fail-closed configuration, readiness, isolation, and pruning checks.
4. Explain any change to the Dockerfile, Compose topology, node flags, volume boundaries, signature verification, or pruning allowlist.
5. Include live Ubuntu 24.04 validation for runtime behavior changes. Redact all infrastructure identifiers from the evidence.

## Local checks

Run the syntax and Compose checks used by CI:

```bash
bash -n scripts/*.sh
PYTHONPYCACHEPREFIX=/tmp/hyperliquid-peering-pycache \
  python3 -m py_compile scripts/*.py
docker compose --env-file .env.example config --quiet
```

These checks read `.env.example` directly. Never copy it over a configured `.env`; that would overwrite your peer settings.

The checked-in placeholders must continue to fail the runtime configuration gate. A positive Quicknode-mode test requires privately supplied, allowlisted values and must never print or commit them.

Runtime changes should also repeat the relevant checks from the [README](README.md): image build, clean Compose startup, readiness, peer isolation, persistence, retention, and recovery.

## Pull requests

Keep pull requests focused, describe the operator-visible impact, list the commands you ran, and call out any behavior that still needs Infrastructure or Product confirmation.
