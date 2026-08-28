#!/usr/bin/env bash
# Use the probe-verified Agent-image Python and verify a bad lock fails closed.
set -euo pipefail

PYTHON_BIN=/opt/hermes/.venv/bin/python
[[ -x "$PYTHON_BIN" ]] || { printf 'invalid-lock entrypoint: missing %s\n' "$PYTHON_BIN" >&2; exit 2; }
export PYTHON_BIN
exec /poc/tests/locked-failure.sh
