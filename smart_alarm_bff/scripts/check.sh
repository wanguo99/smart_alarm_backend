#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT_DIR/src"

python3 -m compileall -q "$ROOT_DIR/src" "$ROOT_DIR/tests"
python3 -m unittest discover -s "$ROOT_DIR/tests" -p 'test_*.py'
