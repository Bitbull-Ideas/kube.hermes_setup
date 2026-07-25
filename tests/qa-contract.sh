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

printf 'QA contract checks passed\n'
