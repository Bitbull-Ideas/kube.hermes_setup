#!/usr/bin/env bash
# Exchange and restore both generation pairs from an independent Agent process.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SOFTWARE_ROOT:?}"
: "${TEST_SOURCE_DIGEST:?}"
initial_python_current="$(readlink "$SOFTWARE_ROOT/python/current")"
initial_python_previous="$(readlink "$SOFTWARE_ROOT/python/previous")"
initial_node_current="$(readlink "$SOFTWARE_ROOT/node/current")"
initial_node_previous="$(readlink "$SOFTWARE_ROOT/node/previous")"
python_count="$(find "$SOFTWARE_ROOT/python/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)"
node_count="$(find "$SOFTWARE_ROOT/node/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)"

"$ROOT_DIR/rollback-generation.sh" python >/dev/null
"$ROOT_DIR/rollback-generation.sh" node >/dev/null
[[ "$(readlink "$SOFTWARE_ROOT/python/current")" == "$initial_python_previous" ]]
[[ "$(readlink "$SOFTWARE_ROOT/python/previous")" == "$initial_python_current" ]]
[[ "$(readlink "$SOFTWARE_ROOT/node/current")" == "$initial_node_previous" ]]
[[ "$(readlink "$SOFTWARE_ROOT/node/previous")" == "$initial_node_current" ]]
"$SOFTWARE_ROOT/python/current/bin/python" -c 'import pyfiglet'
"$SOFTWARE_ROOT/node/current/bin/node" --version >/dev/null
"$SOFTWARE_ROOT/node/current/bin/npm" --version >/dev/null
"$SOFTWARE_ROOT/node/current/bin/npx" --version >/dev/null

"$ROOT_DIR/rollback-generation.sh" python >/dev/null
"$ROOT_DIR/rollback-generation.sh" node >/dev/null
[[ "$(readlink "$SOFTWARE_ROOT/python/current")" == "$initial_python_current" ]]
[[ "$(readlink "$SOFTWARE_ROOT/python/previous")" == "$initial_python_previous" ]]
[[ "$(readlink "$SOFTWARE_ROOT/node/current")" == "$initial_node_current" ]]
[[ "$(readlink "$SOFTWARE_ROOT/node/previous")" == "$initial_node_previous" ]]
[[ "$(find "$SOFTWARE_ROOT/python/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$python_count" ]]
[[ "$(find "$SOFTWARE_ROOT/node/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$node_count" ]]
! find "$SOFTWARE_ROOT/python/staging" "$SOFTWARE_ROOT/node/staging" -mindepth 1 -print -quit | grep -q .
EXPECTED_SOFTWARE_ROOT="${EXPECTED_SOFTWARE_ROOT:-$SOFTWARE_ROOT}" python3 "$ROOT_DIR/verify-state.py"
printf 'rollback-cycle=PASS\n'
