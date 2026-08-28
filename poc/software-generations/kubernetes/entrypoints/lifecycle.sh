#!/usr/bin/env bash
# Use the probe-verified Agent-image runtimes and run the full lifecycle builder.
set -euo pipefail

PYTHON_BIN=/opt/hermes/.venv/bin/python
NODE_SRC=/usr/local/bin/node
NPM_SRC=/usr/local/lib/node_modules/npm
[[ -x "$PYTHON_BIN" ]] || { printf 'lifecycle entrypoint: missing %s\n' "$PYTHON_BIN" >&2; exit 2; }
[[ -f "$NODE_SRC" && -x "$NODE_SRC" ]] || { printf 'lifecycle entrypoint: invalid %s\n' "$NODE_SRC" >&2; exit 2; }
for required in bin/npm-cli.js bin/npx-cli.js package.json; do
  [[ -f "$NPM_SRC/$required" ]] || { printf 'lifecycle entrypoint: missing %s/%s\n' "$NPM_SRC" "$required" >&2; exit 2; }
done
export PYTHON_BIN NODE_SRC NPM_SRC
exec /poc/tests/lifecycle.sh
