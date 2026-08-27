#!/usr/bin/env bash
set -euo pipefail

export ENV_FILE="${ENV_FILE:-/run/hyperliquid-input/node.env}"
export RUNTIME_DIR="${RUNTIME_DIR:-/run/hyperliquid-config}"

/usr/local/bin/render-config.sh
/usr/local/bin/verify-config.sh
