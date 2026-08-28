#!/usr/bin/env bash
# Verify the Agent-built generation from an independent WebUI image.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SOFTWARE_ROOT:?}"
: "${TEST_SOURCE_DIGEST:?}"
: "${EXPECTED_INHERITED_LD_LIBRARY_PATH:?}"
expected_inherited="$EXPECTED_INHERITED_LD_LIBRARY_PATH"
[[ "${LD_LIBRARY_PATH:-}" == "$expected_inherited" ]]
EXPECTED_SOFTWARE_ROOT="${EXPECTED_SOFTWARE_ROOT:-$SOFTWARE_ROOT}" \
  EXPECTED_INHERITED_LD_LIBRARY_PATH="$expected_inherited" \
  python3 "$ROOT_DIR/verify-webui-state.py"
node_generation="$(readlink "$SOFTWARE_ROOT/node/current")"
private="$SOFTWARE_ROOT/node/$node_generation/lib"
actual="$("$SOFTWARE_ROOT/node/current/bin/node" -p 'process.env.LD_LIBRARY_PATH')"
[[ "$actual" == "$private:$expected_inherited" ]]
"$SOFTWARE_ROOT/node/current/bin/node" --version >/dev/null
"$SOFTWARE_ROOT/node/current/bin/npm" --version >/dev/null
"$SOFTWARE_ROOT/node/current/bin/npx" --version >/dev/null
printf 'webui-cross-image=PASS python_execution=SKIPPED_METADATA_ONLY effective_ld_library_path=%s\n' "$actual"
