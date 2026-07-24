#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT_DIR/src"
PYTHON="${PYTHON:-$ROOT_DIR/.venv/bin/python}"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON=python3
fi

"$PYTHON" -m compileall -q "$ROOT_DIR/src" "$ROOT_DIR/tests"
"$PYTHON" -m unittest discover -s "$ROOT_DIR/tests" -p 'test_*.py'
