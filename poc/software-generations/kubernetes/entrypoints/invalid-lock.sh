#!/usr/bin/env bash
# Use the probe-verified Agent-image Python and verify a bad lock fails closed.
set -euo pipefail

PYTHON_BIN=/usr/bin/python3.13
cp -L /poc/requirements-bad.lock /test-tmp/requirements-bad.lock
chmod 0444 /test-tmp/requirements-bad.lock
REQUIREMENTS_BAD=/test-tmp/requirements-bad.lock
[[ -x "$PYTHON_BIN" ]] || { printf 'invalid-lock entrypoint: missing %s\n' "$PYTHON_BIN" >&2; exit 2; }
export PYTHON_BIN REQUIREMENTS_BAD
exec /poc/tests/locked-failure.sh
