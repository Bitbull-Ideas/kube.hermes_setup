#!/usr/bin/env bash
# Use the probe-verified Agent-image runtimes and run the full lifecycle builder.
set -euo pipefail

PYTHON_BIN=/usr/bin/python3.13
NODE_SRC=/usr/local/bin/node
NPM_SRC=/usr/local/lib/node_modules/npm
cp -L /poc/requirements-a.lock /test-tmp/requirements-a.lock
cp -L /poc/requirements-b.lock /test-tmp/requirements-b.lock
cp -L /poc/requirements-bad.lock /test-tmp/requirements-bad.lock
chmod 0444 /test-tmp/requirements-a.lock /test-tmp/requirements-b.lock /test-tmp/requirements-bad.lock
REQUIREMENTS_A=/test-tmp/requirements-a.lock
REQUIREMENTS_B=/test-tmp/requirements-b.lock
REQUIREMENTS_BAD=/test-tmp/requirements-bad.lock
[[ -x "$PYTHON_BIN" ]] || { printf 'lifecycle entrypoint: missing %s\n' "$PYTHON_BIN" >&2; exit 2; }
[[ -f "$NODE_SRC" && -x "$NODE_SRC" ]] || { printf 'lifecycle entrypoint: invalid %s\n' "$NODE_SRC" >&2; exit 2; }
for required in bin/npm-cli.js bin/npx-cli.js package.json; do
  [[ -f "$NPM_SRC/$required" ]] || { printf 'lifecycle entrypoint: missing %s/%s\n' "$NPM_SRC" "$required" >&2; exit 2; }
done
export PYTHON_BIN NODE_SRC NPM_SRC REQUIREMENTS_A REQUIREMENTS_B REQUIREMENTS_BAD
exec /poc/tests/lifecycle.sh
