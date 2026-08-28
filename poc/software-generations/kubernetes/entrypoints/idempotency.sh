#!/usr/bin/env bash
# Use the probe-verified Agent-image runtimes and verify unchanged reconciliation.
set -euo pipefail

PYTHON_BIN=/opt/hermes/.venv/bin/python
NODE_SRC=/usr/local/bin/node
NPM_SRC=/usr/local/lib/node_modules/npm
cp -L /poc/requirements-a.lock /test-tmp/requirements-a.lock
chmod 0444 /test-tmp/requirements-a.lock
REQUIREMENTS_A=/test-tmp/requirements-a.lock
[[ -x "$PYTHON_BIN" ]] || { printf 'idempotency entrypoint: missing %s\n' "$PYTHON_BIN" >&2; exit 2; }
[[ -f "$NODE_SRC" && -x "$NODE_SRC" ]] || { printf 'idempotency entrypoint: invalid %s\n' "$NODE_SRC" >&2; exit 2; }
for required in bin/npm-cli.js bin/npx-cli.js package.json; do
  [[ -f "$NPM_SRC/$required" ]] || { printf 'idempotency entrypoint: missing %s/%s\n' "$NPM_SRC" "$required" >&2; exit 2; }
done
export PYTHON_BIN NODE_SRC NPM_SRC REQUIREMENTS_A
exec /poc/tests/idempotency.sh
