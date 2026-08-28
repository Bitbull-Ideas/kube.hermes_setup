#!/usr/bin/env bash
# Purpose: Enforce the repository's documented quality-assurance acceptance contract.
# Scope: Ensure AGENTS.md and docs/qa.md require real Linux/K3s validation, full-stack
#        coverage, failure-state checks, reinstall checks, and explicit blocked-gate handling.
# Requirements: Bash, grep, and repository documentation.
# Usage: ./tests/qa-contract.sh
# Exit status: 0 means the required QA contract is documented; non-zero identifies a gap.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$ROOT_DIR/AGENTS.md"
QA_DOC="$ROOT_DIR/docs/qa.md"
MANIFEST="$ROOT_DIR/manifests/hermes.yaml.tpl"

# The WebUI image must receive a complete, runnable Node/npm/npx toolchain
# from the Agent image without replacing the WebUI image's own loader path.
# Candidate runtimes are validated off-path and activated through one pointer.
grep -Fq 'cp -a "$npm_source" "$runtime_stage/lib/node_modules/npm"' "$MANIFEST"
grep -Fq 'runtime_stage="$runtimes/.$runtime_key.$$"' "$MANIFEST"
grep -Fq 'LD_LIBRARY_PATH="$runtime_stage/lib" "$runtime_stage/libexec/node" --version' "$MANIFEST"
grep -Fq 'mv -fT "$current_tmp" "$node_root/current"' "$MANIFEST"
grep -Fq 'runtime="$(readlink -f "$node_root/current")"' "$MANIFEST"
grep -Fq 'NODE_LAUNCHER' "$MANIFEST"
grep -Fq 'NPM_LAUNCHER' "$MANIFEST"
grep -Fq 'NPX_LAUNCHER' "$MANIFEST"
grep -Fq 'current="$(printenv LD_LIBRARY_PATH 2>/dev/null || true)"' "$MANIFEST"
! grep -Fq '        - name: LD_LIBRARY_PATH' "$MANIFEST"
grep -Fq 'name: npm_config_yes' "$MANIFEST"
! grep -Fq 'HERMES_NPX_SETUP' "$MANIFEST"

# Agent and Dashboard must not emit connection-refused readiness Warnings during
# ordinary restart/reinstall startup on the accepted K3s target.
python3 - "$MANIFEST" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text()
for name in ('hermes-agent','hermes-dashboard'):
    start=text.index(f'kind: Deployment\nmetadata:\n  name: {name}\n')
    end=text.find('\n---\n',start)
    block=text[start:end if end >= 0 else None]
    match=re.search(r'readinessProbe:\n(?:.*\n){0,8}?\s+initialDelaySeconds:\s*(\d+)',block)
    assert match and int(match.group(1)) >= 60, (name, match.group(1) if match else None)
PY

# Required maintainer guidance must remain present in AGENTS.md.
for needle in \
  'live Linux/K3s or real-VM test is mandatory' \
  'static rendering, fake-`kubectl`, or Agent-only deployment is never sufficient' \
  'full-stack case is mandatory' \
  'CrashLoopBackOff' \
  '--previous' \
  'Secret hash stability' \
  'mark unavailable gates as blocked'; do
  grep -Fqi -- "$needle" "$AGENTS"
done

# Required acceptance coverage must remain present in docs/qa.md.
for needle in \
  'fresh disposable Linux/K3s VM' \
  'Agent-only' \
  'Dashboard' \
  'WebUI' \
  'Browserless' \
  'full' \
  'reinstall' \
  'CrashLoopBackOff' \
  'invalid credentials rejected' \
  'real Chromium'; do
  grep -Fqi "$needle" "$QA_DOC"
done

# Doctor must validate optional WebUI dependencies only when their features are enabled.
python3 - "$ROOT_DIR/doctor.sh" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
webui_source = text.split("check_webui_agent_source() {", 1)[1].split("\n}", 1)[0]
addon_runtime = text.split("check_addon_python_runtime() {", 1)[1].split("\n}", 1)[0]

assert 'is_truthy "$HERMES_BROWSER_ENABLED" || return 0' in webui_source
assert 'webui agent source mount exists' in webui_source
assert 'webui BROWSER_CDP_URL configured' in webui_source
assert 'is_truthy "${HERMES_ANSIBLE_SETUP:-false}" || return 0' in addon_runtime
PY

printf 'QA contract checks passed\n'
