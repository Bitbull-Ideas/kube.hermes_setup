#!/usr/bin/env bash
# Reconcile selected A generations on a populated PVC and prove no state drift.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SOFTWARE_ROOT:?}"
: "${PYTHON_BIN:?}"
: "${NODE_SRC:?}"
: "${NPM_SRC:?}"
: "${TEST_SOURCE_DIGEST:?}"
REQUIREMENTS_A="${REQUIREMENTS_A:-$ROOT_DIR/requirements-a.lock}"
state() {
  local component="$1"
  printf '%s|%s|%s|%s' \
    "$(readlink "$SOFTWARE_ROOT/$component/current")" \
    "$(readlink "$SOFTWARE_ROOT/$component/previous")" \
    "$(find "$SOFTWARE_ROOT/$component/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
    "$(find "$SOFTWARE_ROOT/$component/staging" -mindepth 1 | wc -l)"
}
py_before="$(state python)"
node_before="$(state node)"
export LOCKFILE="$REQUIREMENTS_A" BUILDER_IMAGE_DIGEST="$TEST_SOURCE_DIGEST"
py_hash="$($ROOT_DIR/python/reconcile.sh)"
export SOURCE_IMAGE_DIGEST="$TEST_SOURCE_DIGEST"
node_hash="$($ROOT_DIR/node/reconcile.sh)"
[[ "$(readlink "$SOFTWARE_ROOT/python/current")" == "generations/$py_hash" ]]
[[ "$(readlink "$SOFTWARE_ROOT/node/current")" == "generations/$node_hash" ]]
[[ "$(state python)" == "$py_before" ]]
[[ "$(state node)" == "$node_before" ]]
EXPECTED_SOFTWARE_ROOT="${EXPECTED_SOFTWARE_ROOT:-$SOFTWARE_ROOT}" \
  python3 "$ROOT_DIR/verify-state.py"
printf 'idempotency-verifier=PASS python=%s node=%s\n' "$py_hash" "$node_hash"
