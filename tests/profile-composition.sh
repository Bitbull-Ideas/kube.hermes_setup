#!/usr/bin/env bash
# Purpose: Verify bootstrap profile composition and profile-specific defaults.
# Scope: Check shared/profile files, selected skills, optional Ansible and SSH content,
#        addon requirements, and cleanup/rebuild behavior.
# Requirements: Bash, Python 3, standard utilities, and repository bootstrap sources.
# Usage: ./tests/profile-composition.sh
# Exit status: 0 means every profile composition contract passed; non-zero identifies a failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-profile-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HERMES_INSTALL_LIB_ONLY=true
# shellcheck source=../install.sh
source "$ROOT_DIR/install.sh"
RENDER_DIR="$TMP_DIR/rendered"

# Reset variables that profile composition may derive or preserve.
reset_profile_env() {
  unset HERMES_BOOTSTRAP_DIR HERMES_SSH_SETUP HERMES_SSH_GENERATE_KEY
  unset HERMES_NPX_SETUP
  unset HERMES_ANSIBLE_SETUP HERMES_ANSIBLE_CONFIG HERMES_ADDON_REQUIREMENTS
  unset HERMES_PROFILE_DEFAULT_SSH_SETUP HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP HERMES_PROFILE_DEFAULT_NPX_SETUP
  unset HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS HERMES_PROFILE_REQUIREMENTS_SELECTED
}

assert_file() {
  [[ -f "$1" ]] || { printf 'missing expected file: %s\n' "$1" >&2; exit 1; }
}

assert_absent() {
  [[ ! -e "$1" ]] || { printf 'unexpected path: %s\n' "$1" >&2; exit 1; }
}

assert_skill_set() {
  local stage="$1"
  shift
  local expected actual
  expected="$(printf '%s\n' "$@" | sort)"
  actual="$(find "$stage/skills" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)"
  [[ "$actual" == "$expected" ]] || {
    printf 'skill set mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  }
}

# ---- personal-assistant ----
reset_profile_env
HERMES_BOOTSTRAP_PROFILE=personal-assistant
apply_profile_defaults "$HERMES_BOOTSTRAP_PROFILE"
compose_profile_bootstrap "$HERMES_BOOTSTRAP_PROFILE"
personal_stage="$HERMES_BOOTSTRAP_DIR"
assert_skill_set "$personal_stage" coaching-recurring-patterns hermes-log-watchdog hermes-workspace-manager markdown-pdf systemische-psychologie
assert_file "$personal_stage/workspace/POST_SETUP.md"
assert_absent "$personal_stage/POST_SETUP.md"
cmp -s "$ROOT_DIR/examples/bootstrap-shared/workspace/POST_SETUP.md" "$personal_stage/workspace/POST_SETUP.md"
assert_absent "$personal_stage/workspace/ansible"
[[ "$HERMES_SSH_SETUP" == true && "$HERMES_ANSIBLE_SETUP" == false ]]
[[ "$HERMES_NPX_SETUP" == false ]]
[[ "$HERMES_ADDON_REQUIREMENTS" == "$ROOT_DIR/examples/bootstrap-profiles/personal-assistant/requirements.txt" ]]

# ---- universal-system-architect ----
reset_profile_env
HERMES_BOOTSTRAP_PROFILE=universal-system-architect
apply_profile_defaults "$HERMES_BOOTSTRAP_PROFILE"
compose_profile_bootstrap "$HERMES_BOOTSTRAP_PROFILE"
architect_stage="$HERMES_BOOTSTRAP_DIR"
assert_skill_set "$architect_stage" github-setup-access hermes-log-watchdog hermes-workspace-ansible hermes-workspace-git hermes-workspace-manager markdown-pdf
assert_file "$architect_stage/workspace/POST_SETUP.md"
assert_absent "$architect_stage/POST_SETUP.md"
cmp -s "$ROOT_DIR/examples/bootstrap-shared/workspace/POST_SETUP.md" "$architect_stage/workspace/POST_SETUP.md"
assert_file "$architect_stage/workspace/ansible/ansible.cfg"
[[ "$HERMES_SSH_SETUP" == true && "$HERMES_ANSIBLE_SETUP" == true ]]
[[ "$HERMES_NPX_SETUP" == true ]]
[[ "$HERMES_ADDON_REQUIREMENTS" == "$ROOT_DIR/examples/bootstrap-profiles/universal-system-architect/requirements.txt" ]]

# ---- universal-system-administrator ----
reset_profile_env
HERMES_BOOTSTRAP_PROFILE=universal-system-administrator
apply_profile_defaults "$HERMES_BOOTSTRAP_PROFILE"
compose_profile_bootstrap "$HERMES_BOOTSTRAP_PROFILE"
admin_stage="$HERMES_BOOTSTRAP_DIR"
assert_skill_set "$admin_stage" ansible-fleet-change github-setup-access hermes-log-watchdog hermes-workspace-ansible hermes-workspace-git hermes-workspace-manager linux-change-safety linux-triage markdown-pdf
assert_file "$admin_stage/workspace/POST_SETUP.md"
assert_absent "$admin_stage/POST_SETUP.md"
cmp -s "$ROOT_DIR/examples/bootstrap-shared/workspace/POST_SETUP.md" "$admin_stage/workspace/POST_SETUP.md"
assert_file "$admin_stage/workspace/ansible/ansible.cfg"
[[ "$HERMES_SSH_SETUP" == true && "$HERMES_ANSIBLE_SETUP" == true ]]
[[ "$HERMES_NPX_SETUP" == false ]]
[[ "$HERMES_ADDON_REQUIREMENTS" == "$ROOT_DIR/examples/bootstrap-profiles/universal-system-administrator/requirements.txt" ]]
grep -q 'Scope boundary: Hermes runtime vs. managed targets' "$admin_stage/SOUL.md"
grep -q 'Do not administer the runtime as a target host' "$admin_stage/SOUL.md"
grep -q 'Do \*\*not\*\* use this skill for routine self-maintenance' "$admin_stage/skills/linux-change-safety/SKILL.md"
grep -q 'Do not require `kubectl`, root, `/srv/backup`, `/CHANGES.md`' "$admin_stage/skills/github-setup-access/SKILL.md"
grep -q 'Routine self-maintenance of the active Hermes runtime' "$admin_stage/workspace/AGENTS.md"

# ---- operator override test ----
reset_profile_env
HERMES_BOOTSTRAP_PROFILE=universal-system-architect
HERMES_SSH_SETUP=false
HERMES_ANSIBLE_SETUP=false
HERMES_ADDON_REQUIREMENTS=
apply_profile_defaults "$HERMES_BOOTSTRAP_PROFILE"
compose_profile_bootstrap "$HERMES_BOOTSTRAP_PROFILE"
override_stage="$HERMES_BOOTSTRAP_DIR"
assert_absent "$override_stage/workspace/ansible"
[[ "$HERMES_SSH_SETUP" == false && "$HERMES_ANSIBLE_SETUP" == false ]]
[[ "$HERMES_NPX_SETUP" == true ]]
[[ -z "$HERMES_ADDON_REQUIREMENTS" ]]

reset_profile_env
HERMES_BOOTSTRAP_PROFILE=universal-system-architect
HERMES_ANSIBLE_SETUP=true
HERMES_ANSIBLE_CONFIG=/workspace/custom/ansible.cfg
HERMES_ADDON_REQUIREMENTS=
prepare_defaults
[[ "$HERMES_ANSIBLE_CONFIG" == /workspace/custom/ansible.cfg ]]
assert_file "$HERMES_BOOTSTRAP_DIR/workspace/ansible/ansible.cfg"

custom_bootstrap="$TMP_DIR/operator-bootstrap"
mkdir -p "$custom_bootstrap/workspace/ansible"
printf '%s\n' '[defaults]' > "$custom_bootstrap/workspace/ansible/operator.cfg"
reset_profile_env
HERMES_BOOTSTRAP_PROFILE=universal-system-architect
HERMES_BOOTSTRAP_DIR="$custom_bootstrap"
HERMES_ANSIBLE_SETUP=false
HERMES_ADDON_REQUIREMENTS=
prepare_defaults
[[ "$HERMES_BOOTSTRAP_DIR" == "$custom_bootstrap" ]]
assert_file "$custom_bootstrap/workspace/ansible/operator.cfg"

printf 'profile composition tests passed\n'
