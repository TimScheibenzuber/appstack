#!/usr/bin/env bash
# Convenience launcher: ensures the venv exists, deps are installed, then runs.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d ".venv" ]; then
  echo "Creating virtual environment..."
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.11 .venv
    uv pip install --python .venv -r requirements.txt
  else
    python3.11 -m venv .venv
    ./.venv/bin/pip install -r requirements.txt
  fi
fi

exec ./.venv/bin/python main.py "$@"
