#!/bin/bash
# Stress test runner for tandem.nvim
#
# Usage:
#   Terminal 1: TANDEM_TOKEN=your-jwt ./scripts/stress_test.sh A
#   Terminal 2: TANDEM_TOKEN=your-jwt ./scripts/stress_test.sh B
#
# Environment variables:
#   TANDEM_TOKEN    - JWT token for authentication (required)
#   TANDEM_HOST     - Server host (default: localhost:8080)
#   TANDEM_DOC      - Document ID (default: stress-test-<timestamp>)
#
# Prerequisites:
#   - confluxd running
#   - tandem.nvim built (make build)

set -e

if [[ -z "$TANDEM_TOKEN" ]]; then
    echo "ERROR: TANDEM_TOKEN environment variable is required"
    echo "Usage: TANDEM_TOKEN=your-jwt ./scripts/stress_test.sh [A|B]"
    exit 1
fi

INSTANCE="${1:-A}"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TANDEM_HOST="${TANDEM_HOST:-localhost:8080}"
TANDEM_DOC="${TANDEM_DOC:-stress-test}"
SERVER_URL="ws://${TANDEM_HOST}/ws/${TANDEM_DOC}?token=${TANDEM_TOKEN}"

echo "=== Tandem Stress Test - Instance $INSTANCE ==="
echo "Plugin dir: $PLUGIN_DIR"
echo "Server URL: $SERVER_URL"
echo ""
echo "Instructions:"
echo "  1. Run :StressTest to start the test"
echo "  2. After completion, run :StressCompare"
echo "  3. Compare hashes between instances"
echo ""

cd "$PLUGIN_DIR"

nvim --clean \
    -c "set rtp+=$PLUGIN_DIR" \
    -c "lua package.path = package.path .. ';$PLUGIN_DIR/lua/?.lua;$PLUGIN_DIR/lua/?/init.lua'" \
    -c "lua require('tandem').setup()" \
    -c "TandemJoin $SERVER_URL" \
    -c "luafile lua/tandem/stress_test.lua"
