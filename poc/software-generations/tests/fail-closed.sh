#!/usr/bin/env bash
# Focused regression tests for fail-closed generation validation and rollback.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SOFTWARE_ROOT:?SOFTWARE_ROOT is required}"
: "${TEST_TMP:?TEST_TMP is required}"
PYTHON_BIN="${PYTHON_BIN:-/opt/data/uv/python/cpython-3.13-linux-x86_64-gnu/bin/python3}"
NODE_SRC="${NODE_SRC:-/opt/data/node/bin/node}"
NPM_SRC="${NPM_SRC:-/opt/data/node/lib/node_modules/npm}"
NODE_SRC_ORIGINAL="$NODE_SRC"
NPM_SRC_ORIGINAL="$NPM_SRC"
TEST_SOURCE_DIGEST="${TEST_SOURCE_DIGEST:-sha256:1111111111111111111111111111111111111111111111111111111111111111}"
PY_RECONCILE="$ROOT_DIR/python/reconcile.sh"
NODE_RECONCILE="$ROOT_DIR/node/reconcile.sh"
ROLLBACK="$ROOT_DIR/rollback-generation.sh"
mkdir -p "$SOFTWARE_ROOT" "$TEST_TMP"

link_state() {
  local component="$1"
  printf '%s|%s|%s|%s' \
    "$(readlink "$SOFTWARE_ROOT/$component/current" 2>/dev/null || true)" \
    "$(readlink "$SOFTWARE_ROOT/$component/previous" 2>/dev/null || true)" \
    "$(find "$SOFTWARE_ROOT/$component/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
    "$(find "$SOFTWARE_ROOT/$component/staging" -mindepth 1 | wc -l)"
}
assert_clean() {
  local component="$1"
  ! find "$SOFTWARE_ROOT/$component/staging" -mindepth 1 -print -quit | grep -q .
  ! find "$SOFTWARE_ROOT/$component/generations" -mindepth 1 -maxdepth 1 -type d ! -exec test -f '{}/.complete' ';' -print -quit | grep -q .
}

export SOFTWARE_ROOT PYTHON_BIN BUILDER_IMAGE_DIGEST="$TEST_SOURCE_DIGEST"
export LOCKFILE="$ROOT_DIR/requirements-a.lock"
py_a="$($PY_RECONCILE)"
export LOCKFILE="$ROOT_DIR/requirements-b.lock"
py_b="$($PY_RECONCILE)"
[[ "$py_a" != "$py_b" ]]
py_meta="$SOFTWARE_ROOT/python/generations/$py_a/metadata.json"
cp "$py_meta" "$TEST_TMP/python-metadata.good"
py_before="$(link_state python)"
printf '{}\n' > "$py_meta"
export LOCKFILE="$ROOT_DIR/requirements-a.lock"
if "$PY_RECONCILE" >"$TEST_TMP/python-corrupt.out" 2>&1; then
  printf '%s\n' 'corrupt Python metadata unexpectedly reconciled' >&2
  exit 1
fi
[[ "$(link_state python)" == "$py_before" ]]
assert_clean python
mv "$TEST_TMP/python-metadata.good" "$py_meta"
[[ "$($PY_RECONCILE)" == "$py_a" ]]
"$SOFTWARE_ROOT/python/current/bin/python" -c 'import pyfiglet, six'
assert_clean python
printf '%s\n' 'focused-python-corruption=PASS'

export NODE_SRC NPM_SRC SOURCE_IMAGE_DIGEST="$TEST_SOURCE_DIGEST"
node_a="$($NODE_RECONCILE)"
npm_b="$TEST_TMP/npm-b"
cp -a "$NPM_SRC" "$npm_b"
printf '%s\n' generation-b > "$npm_b/.hermes-poc-generation-b"
export NPM_SRC="$npm_b"
node_b="$($NODE_RECONCILE)"
[[ "$node_a" != "$node_b" ]]
"$ROLLBACK" node >/dev/null
[[ "$(readlink "$SOFTWARE_ROOT/node/current")" == "generations/$node_a" ]]
[[ "$(readlink "$SOFTWARE_ROOT/node/previous")" == "generations/$node_b" ]]

node_wrapper="$SOFTWARE_ROOT/node/generations/$node_a/bin/node"
cp "$node_wrapper" "$TEST_TMP/node-wrapper.good"
node_before="$(link_state node)"
printf '#!/bin/sh\nexit 0\n' > "$node_wrapper"
chmod 755 "$node_wrapper"
export NODE_SRC="$NODE_SRC_ORIGINAL"
export NPM_SRC="$NPM_SRC_ORIGINAL"
if "$NODE_RECONCILE" >"$TEST_TMP/node-corrupt.out" 2>&1; then
  printf '%s\n' 'corrupt Node wrapper unexpectedly reconciled' >&2
  exit 1
fi
[[ "$(link_state node)" == "$node_before" ]]
assert_clean node
mv "$TEST_TMP/node-wrapper.good" "$node_wrapper"
[[ "$($NODE_RECONCILE)" == "$node_a" ]]
"$SOFTWARE_ROOT/node/current/bin/node" --version >/dev/null
assert_clean node
printf '%s\n' 'focused-node-corruption=PASS'

previous_payload="$SOFTWARE_ROOT/node/generations/$node_b/libexec/node"
cp "$previous_payload" "$TEST_TMP/previous-payload.good"
rollback_before="$(link_state node)"
printf 'corrupt\n' > "$previous_payload"
chmod 755 "$previous_payload"
if "$ROLLBACK" node >"$TEST_TMP/rollback-corrupt.out" 2>&1; then
  printf '%s\n' 'rollback accepted corrupt previous Node payload' >&2
  exit 1
fi
[[ "$(link_state node)" == "$rollback_before" ]]
mv "$TEST_TMP/previous-payload.good" "$previous_payload"
"$ROLLBACK" node >/dev/null
[[ "$(readlink "$SOFTWARE_ROOT/node/current")" == "generations/$node_b" ]]
[[ "$(readlink "$SOFTWARE_ROOT/node/previous")" == "generations/$node_a" ]]
"$ROLLBACK" node >/dev/null
[[ "$(readlink "$SOFTWARE_ROOT/node/current")" == "generations/$node_a" ]]
[[ "$(readlink "$SOFTWARE_ROOT/node/previous")" == "generations/$node_b" ]]
assert_clean node
printf '%s\n' 'focused-rollback-corruption=PASS'
printf 'focused-fail-closed-tests=PASS root=%s\n' "$SOFTWARE_ROOT"
