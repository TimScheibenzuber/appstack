#!/usr/bin/env bash
# Runs the ClaudeKit test suite including the real-HTTP integration tests against a local
# mock of the Messages API. Usage: scripts/integration-test.sh [extra swift test args]
set -euo pipefail
cd "$(dirname "$0")/.."

port_file="$(mktemp)"
python3 scripts/mock_server.py > "$port_file" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -f "$port_file"' EXIT

for _ in $(seq 1 50); do
  [[ -s "$port_file" ]] && break
  sleep 0.1
done
port="$(head -n 1 "$port_file")"
[[ -n "$port" ]] || { echo "mock server did not start" >&2; exit 1; }

CLAUDEKIT_MOCK_PORT="$port" swift test "$@"
