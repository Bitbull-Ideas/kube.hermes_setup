#!/usr/bin/env bash
# Prove a hash-invalid Python declaration cannot change persisted state.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SOFTWARE_ROOT:?}"
: "${PYTHON_BIN:?}"
: "${TEST_SOURCE_DIGEST:?}"
: "${TEST_TMP:?}"
REQUIREMENTS_BAD="${REQUIREMENTS_BAD:-$ROOT_DIR/requirements-bad.lock}"
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
export LOCKFILE="$REQUIREMENTS_BAD" BUILDER_IMAGE_DIGEST="$TEST_SOURCE_DIGEST"
if "$ROOT_DIR/python/reconcile.sh" >"$TEST_TMP/locked-failure.out" 2>&1; then
  printf '%s\n' 'bad lock unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(state python)" == "$py_before" ]]
[[ "$(state node)" == "$node_before" ]]
EXPECTED_SOFTWARE_ROOT="${EXPECTED_SOFTWARE_ROOT:-$SOFTWARE_ROOT}" \
  python3 "$ROOT_DIR/verify-state.py"
printf 'locked-dependency-failure=PASS\n'
