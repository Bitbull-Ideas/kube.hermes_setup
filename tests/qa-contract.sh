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
# from the Agent image, including the shared library absent from WebUI.
grep -Fq 'cp -a /usr/local/lib/node_modules/npm /opt/data/node/lib/node_modules/npm' "$MANIFEST"
grep -Fq 'ln -sfn /opt/data/node/lib/node_modules/npm/bin/npx-cli.js /opt/data/node/bin/npx' "$MANIFEST"
grep -Fq 'ldd /usr/local/bin/node' "$MANIFEST"
grep -Fq 'name: LD_LIBRARY_PATH' "$MANIFEST"
grep -Fq 'HERMES_WEBUI_EXTRA_LD_LIBRARY_PATH' "$MANIFEST"
grep -Fq 'name: npm_config_yes' "$MANIFEST"
grep -Fq 'kube-hermes-setup.example.com/npx-setup' "$MANIFEST"
grep -Fq 'rm -rf /opt/data/node/lib/node_modules/npm' "$MANIFEST"

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
