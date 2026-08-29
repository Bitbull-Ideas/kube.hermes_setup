#!/usr/bin/env bash
# Enforce the supported v2.7.1 release shape and reject experimental PoC artifacts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[[ "$(<VERSION)" == 2.7.1 ]]
grep -Fq '## [v2.7.1] - 2026-08-28' CHANGELOG.md
grep -Fq '## [v2.7.0] - 2026-08-28' CHANGELOG.md
grep -Fq '[Issue #98]' CHANGELOG.md

# A release branch must not ship disconnected proof-of-concept source or docs.
if git ls-files | grep -Eq '(^|/)poc(/|$)|software-generations-poc'; then
  printf 'tracked PoC artifact remains in final release\n' >&2
  git ls-files | grep -E '(^|/)poc(/|$)|software-generations-poc' >&2
  exit 1
fi
! grep -Eqi 'experimental immutable software-generation|software-generation PoC|under `poc/' README.md CHANGELOG.md docs/*.md

# Issue #98 is fixed in the supported WebUI Deployment path.
grep -Fq 'node_root=/opt/data/node' manifests/hermes.yaml.tpl
grep -Fq 'runtime_stage="$runtimes/.$runtime_key.$$"' manifests/hermes.yaml.tpl
grep -Fq 'mv -fT "$current_tmp" "$node_root/current"' manifests/hermes.yaml.tpl
grep -Fq 'runtime="$(readlink -f "$node_root/current")"' manifests/hermes.yaml.tpl
grep -Fq 'NODE_LAUNCHER' manifests/hermes.yaml.tpl
grep -Fq 'NPM_LAUNCHER' manifests/hermes.yaml.tpl
grep -Fq 'NPX_LAUNCHER' manifests/hermes.yaml.tpl
grep -Fq 'current="$(printenv LD_LIBRARY_PATH 2>/dev/null || true)"' manifests/hermes.yaml.tpl
! grep -Fq '        - name: LD_LIBRARY_PATH' manifests/hermes.yaml.tpl

# The production regression is part of the normal repository test tree.
[[ -x tests/node-runtime-launcher.sh ]]

# Password-file automation must never echo the passphrase through the PTY.
grep -Fq '"--echo",' scripts/age_passphrase.py
grep -Fq '"never",' scripts/age_passphrase.py
grep -Fq 'age passphrase helper requires --output PATH' scripts/age_passphrase.py
grep -Fq 'Never forward the captured' scripts/age_passphrase.py
grep -Fq 'age command failed with exit status' scripts/age_passphrase.py

printf 'v2.7.1 final-state contract passed\n'
