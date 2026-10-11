#!/usr/bin/env bash
# Runs the ClaudeKit test suite including the real-HTTP integration tests against a local
# mock of the Messages API. Usage: scripts/integration-test.sh [extra swift test args]
set -euo pipefail
cd "$(dirname "$0")/.."

port_file="$(mktemp)"
log_file="$(mktemp)"
python3 -u scripts/mock_server.py > "$port_file" 2> "$log_file" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -f "$port_file" "$log_file"' EXIT

# First python3 start on a fresh CI machine can take a while.
for _ in $(seq 1 600); do
  [[ -s "$port_file" ]] && break
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
done
port="$(head -n 1 "$port_file")"
if [[ -z "$port" ]]; then
  echo "mock server did not start" >&2
  cat "$log_file" >&2
  exit 1
fi

CLAUDEKIT_MOCK_PORT="$port" swift test "$@"
