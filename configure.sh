#!/usr/bin/env bash
# Purpose: Create an isolated Hermes configuration and optionally run the installer.
# Scope: Drive interactive configuration, answer replay, profile composition, and
#        generation of hermes.env, bootstrap files, and installer artifacts.
# Requirements: Bash, Python 3, standard utilities, and repository bootstrap sources.
# Usage: ./configure.sh [--config-dir PATH] [--answers-file PATH] [--from-answers] [--no-install]
# Exit status: 0 means configuration completed; non-zero identifies invalid input or failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HERMES_CURRENT_CONFIG_DIR:-$ROOT_DIR/current_config}"
ANSWERS_FILE="${HERMES_CONFIGURATION_ANSWERS:-$ROOT_DIR/configuration_answers}"
RUN_INSTALLER=true
FROM_ANSWERS=false
USE_ANSWER_DEFAULTS=false

usage() {
  cat <<'EOF'
Create an isolated Hermes deployment configuration and optionally run install.sh.

Usage:
  ./configure.sh [--config-dir PATH] [--answers-file PATH] [--from-answers] [--no-install]

The default ./current_config directory contains hermes.env, the fully composed
bootstrap tree, and installer artifacts. The root-level configuration_answers
file stores the answers with mode 0600. Both paths are excluded from Git.

Use --from-answers to rebuild current_config after updating the repository
without an interactive reuse question.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir)
      [[ $# -ge 2 && -n "$2" ]] || { printf 'ERROR: --config-dir requires a path.\n' >&2; exit 2; }
      CONFIG_DIR="$2"; shift 2 ;;
    --answers-file)
      [[ $# -ge 2 && -n "$2" ]] || { printf 'ERROR: --answers-file requires a path.\n' >&2; exit 2; }
      ANSWERS_FILE="$2"; shift 2 ;;
    --from-answers) FROM_ANSWERS=true; shift ;;
    --no-install) RUN_INSTALLER=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
CONFIG_DIR="$(mkdir -p "$(dirname "$CONFIG_DIR")" && cd "$(dirname "$CONFIG_DIR")" && pwd)/$(basename "$CONFIG_DIR")"
ANSWERS_FILE="$(mkdir -p "$(dirname "$ANSWERS_FILE")" && cd "$(dirname "$ANSWERS_FILE")" && pwd)/$(basename "$ANSWERS_FILE")"

export HERMES_INSTALL_LIB_ONLY=true
# shellcheck source=install.sh
source "$ROOT_DIR/install.sh"
unset HERMES_INSTALL_LIB_ONLY

prompt_value() {
  local label="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    printf '%s' "${value:-$default}"
  else
    while true; do
      read -r -p "$label: " value
      [[ -n "$value" ]] && { printf '%s' "$value"; return; }
      printf 'A value is required.\n' >&2
    done
  fi
}

ask_yes_no() {
  local label="$1" default="$2" answer suffix
  [[ "$default" == true ]] && suffix='Y/n' || suffix='y/N'
  while true; do
    read -r -p "$label [$suffix]: " answer
    answer="${answer:-$([[ "$default" == true ]] && printf y || printf n)}"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

if [[ "$FROM_ANSWERS" != true && -f "$ANSWERS_FILE" ]]; then
  if ask_yes_no "Reuse existing configuration answers from $ANSWERS_FILE?" true; then
    # Reuse answers as interactive defaults; do not skip the wizard questions.
    # Passwords are never stored in configuration_answers and remain prompt/generate only.
    # shellcheck disable=SC1090
    source "$ANSWERS_FILE"
    USE_ANSWER_DEFAULTS=true
  fi
fi

answer_default() {
  local name="$1" fallback="${2:-}" value=""
  [[ "$USE_ANSWER_DEFAULTS" == true && -v "$name" ]] && value="${!name}"
  printf '%s' "${value:-$fallback}"
}

answer_bool_default() {
  local name="$1" fallback="$2" value=""
  [[ "$USE_ANSWER_DEFAULTS" == true && -v "$name" ]] && value="${!name}"
  [[ "$value" == true || "$value" == false ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

validate_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$1" == *.* ]]
}

prompt_hostname() {
  local label="$1" default="$2" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    validate_hostname "$value" && { printf '%s' "$value"; return; }
    printf 'Enter a DNS hostname such as hermes.example.com.\n' >&2
  done
}

prompt_password() {
  local first second
  while true; do
    read -r -s -p 'Dashboard/WebUI password (leave empty to generate): ' first; printf '\n' >&2
    [[ -z "$first" ]] && { printf ''; return; }
    read -r -s -p 'Confirm Dashboard/WebUI password: ' second; printf '\n' >&2
    [[ "$first" == "$second" ]] || { printf 'Passwords do not match.\n' >&2; continue; }
    if (( ${#first} < 14 )); then
      printf 'Use at least 14 characters, or leave empty for a generated password.\n' >&2
      continue
    fi
    printf '%s' "$first"
    return
  done
}

write_setting() {
  local target="$1" name="$2" value="$3"
  printf '%s=%q\n' "$name" "$value" >> "$target"
}

if [[ "$FROM_ANSWERS" == true ]]; then
  [[ -f "$ANSWERS_FILE" ]] || { printf 'ERROR: answers file not found: %s\n' "$ANSWERS_FILE" >&2; exit 1; }
  # Generated by this script, mode 0600, and Git-ignored.
  # shellcheck disable=SC1090
  source "$ANSWERS_FILE"
  printf 'Rebuilding current_config from %s\n' "$ANSWERS_FILE"
else
  printf '\nHermes Kubernetes configuration wizard\n'
  printf 'The Agent is mandatory. Optional components can be selected independently.\n\n'

  HERMES_NAMESPACE="$(prompt_value 'Kubernetes namespace' "$(answer_default HERMES_NAMESPACE hermes)")"
  profile_default="$(answer_default HERMES_BOOTSTRAP_PROFILE personal-assistant)"
    # Discover available profiles dynamically from the repository
    declare -a profile_names=()
    declare -a profile_descriptions=()
    declare -i index=1
    declare -i default_index=1
    local_profile_dir=""
    local_profile_name=""
    local_soul_line=""
    for local_profile_dir in "$ROOT_DIR/examples/bootstrap-profiles/"*/; do
      [[ -d "$local_profile_dir" ]] || continue
      local_profile_name="$(basename "$local_profile_dir")"
      profile_names+=("$local_profile_name")
      # Read first line of SOUL.md for a one-line description
      local_soul_line=""
      [[ -f "$local_profile_dir/SOUL.md" ]] && local_soul_line="$(head -1 "$local_profile_dir/SOUL.md" 2>/dev/null || true)"
      profile_descriptions+=("${local_soul_line:-$local_profile_name}")
      [[ "$local_profile_name" == "$profile_default" ]] && default_index=$index
      index=$((index + 1))
    done
    declare -i profile_count=$((index - 1))
    while true; do
      printf 'Bootstrap profile:\n'
      index=1
      for local_profile_name in "${profile_names[@]}"; do
        printf '  %d) %s\n' "$index" "$local_profile_name"
        index=$((index + 1))
      done
      read -r -p "Select profile [$default_index]: " profile_choice
      profile_choice="${profile_choice:-$default_index}"
      # Match by number or by exact name
      if [[ "$profile_choice" =~ ^[0-9]+$ ]] && (( profile_choice >= 1 && profile_choice <= profile_count )); then
        HERMES_BOOTSTRAP_PROFILE="${profile_names[$((profile_choice - 1))]}"
        break
      fi
      matched=false
      for local_profile_name in "${profile_names[@]}"; do
        if [[ "$profile_choice" == "$local_profile_name" ]]; then
          HERMES_BOOTSTRAP_PROFILE="$local_profile_name"
          matched=true
          break
        fi
      done
      if [[ "$matched" == true ]]; then
        break
      fi
      printf 'Choose a number or profile name from the list above.\n' >&2
    done

  read -r profile_ssh_default profile_ansible_default < <(
    unset HERMES_SSH_SETUP HERMES_NPX_SETUP HERMES_ANSIBLE_SETUP HERMES_ADDON_REQUIREMENTS
    apply_profile_defaults "$HERMES_BOOTSTRAP_PROFILE"
    printf '%s %s\n' "$HERMES_SSH_SETUP" "$HERMES_ANSIBLE_SETUP"
  )
  [[ "$profile_ssh_default" == true || "$profile_ssh_default" == false ]] || {
    printf 'ERROR: invalid profile SSH default for %s.\n' "$HERMES_BOOTSTRAP_PROFILE" >&2
    exit 1
  }
  [[ "$profile_ansible_default" == true || "$profile_ansible_default" == false ]] || {
    printf 'ERROR: invalid profile Ansible default for %s.\n' "$HERMES_BOOTSTRAP_PROFILE" >&2
    exit 1
  }

  MODEL_PROVIDER="$(prompt_value 'Hermes model provider' "$(answer_default MODEL_PROVIDER openai-codex)")"
  MODEL_NAME="$(prompt_value 'Hermes model' "$(answer_default MODEL_NAME gpt-5.6-luna)")"

  HERMES_AGENT_IMAGE="$(prompt_value 'Hermes Agent container image' "$(answer_default HERMES_AGENT_IMAGE nousresearch/hermes-agent:latest)")"
  HERMES_WEBUI_IMAGE="$(prompt_value 'Hermes WebUI container image' "$(answer_default HERMES_WEBUI_IMAGE ghcr.io/nesquena/hermes-webui:latest)")"
  HERMES_BROWSER_IMAGE="$(prompt_value 'Browserless Chromium container image' "$(answer_default HERMES_BROWSER_IMAGE ghcr.io/browserless/chromium:latest)")"
  HERMES_IMAGE_PULL_POLICY="$(answer_default HERMES_IMAGE_PULL_POLICY IfNotPresent)"
  while true; do
    read -r -p "Image pull policy [$HERMES_IMAGE_PULL_POLICY] (IfNotPresent/Always): " image_pull_policy
    HERMES_IMAGE_PULL_POLICY="${image_pull_policy:-$HERMES_IMAGE_PULL_POLICY}"
    [[ "$HERMES_IMAGE_PULL_POLICY" == IfNotPresent || "$HERMES_IMAGE_PULL_POLICY" == Always ]] && break
    printf 'Choose IfNotPresent or Always.\n' >&2
  done

  HERMES_DASHBOARD_ENABLED="$(answer_bool_default HERMES_DASHBOARD_ENABLED true)"
  HERMES_WEBUI_ENABLED="$(answer_bool_default HERMES_WEBUI_ENABLED true)"
  HERMES_BROWSER_ENABLED="$(answer_bool_default HERMES_BROWSER_ENABLED true)"
  if ask_yes_no 'Install Dashboard?' "$HERMES_DASHBOARD_ENABLED"; then HERMES_DASHBOARD_ENABLED=true; else HERMES_DASHBOARD_ENABLED=false; fi
  if ask_yes_no 'Install WebUI?' "$HERMES_WEBUI_ENABLED"; then HERMES_WEBUI_ENABLED=true; else HERMES_WEBUI_ENABLED=false; fi
  if ask_yes_no 'Install Browserless Chromium?' "$HERMES_BROWSER_ENABLED"; then HERMES_BROWSER_ENABLED=true; else HERMES_BROWSER_ENABLED=false; fi

  WEBUI_HOST="$(answer_default WEBUI_HOST '')"
  DASHBOARD_HOST="$(answer_default DASHBOARD_HOST '')"
  [[ "$HERMES_WEBUI_ENABLED" == true ]] && WEBUI_HOST="$(prompt_hostname 'WebUI hostname' "$(answer_default WEBUI_HOST hermes.example.com)")"
  [[ "$HERMES_DASHBOARD_ENABLED" == true ]] && DASHBOARD_HOST="$(prompt_hostname 'Dashboard hostname' "$(answer_default DASHBOARD_HOST hermes-admin.example.com)")"

  DASHBOARD_AUTH_USER="$(answer_default DASHBOARD_AUTH_USER '')"
  DASHBOARD_AUTH_PASSWORD=''
  if [[ "$HERMES_DASHBOARD_ENABLED" == true || "$HERMES_WEBUI_ENABLED" == true ]]; then
    if [[ "$HERMES_DASHBOARD_ENABLED" == true ]]; then
      DASHBOARD_AUTH_USER="$(prompt_value 'Dashboard username' "$(answer_default DASHBOARD_AUTH_USER admin)")"
      [[ "$DASHBOARD_AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'ERROR: invalid Dashboard username.\n' >&2; exit 1; }
    else
      DASHBOARD_AUTH_USER=admin
    fi
    DASHBOARD_AUTH_PASSWORD="$(prompt_password)"
  fi

  HERMES_ANSIBLE_SETUP="$(answer_bool_default HERMES_ANSIBLE_SETUP "$profile_ansible_default")"
  HERMES_ANSIBLE_VERSION="$(answer_default HERMES_ANSIBLE_VERSION '')"
  HERMES_SSH_SETUP="$(answer_bool_default HERMES_SSH_SETUP "$profile_ssh_default")"
  if ask_yes_no 'Install and configure Ansible?' "$HERMES_ANSIBLE_SETUP"; then
    HERMES_ANSIBLE_SETUP=true
    while true; do
      HERMES_ANSIBLE_VERSION="$(prompt_value 'Ansible package version' "$(answer_default HERMES_ANSIBLE_VERSION 14.1.0)")"
      [[ "$HERMES_ANSIBLE_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] && break
      printf 'Enter a package version such as 14.1.0.\n' >&2
    done
    HERMES_SSH_SETUP=true
    printf 'SSH key setup enabled because Ansible was selected.\n'
  else
    if ask_yes_no 'Prepare a persistent SSH keypair?' "$HERMES_SSH_SETUP"; then HERMES_SSH_SETUP=true; else HERMES_SSH_SETUP=false; fi
  fi

  HERMES_NPX_SETUP="$(answer_bool_default HERMES_NPX_SETUP false)"
  if ask_yes_no 'Prepare Node.js/npx for MCP and skill support?' "$HERMES_NPX_SETUP"; then HERMES_NPX_SETUP=true; else HERMES_NPX_SETUP=false; fi

  HERMES_ADDON_PYTHON_VERSION="$(answer_default HERMES_ADDON_PYTHON_VERSION '')"
  if ask_yes_no 'Install addon Python packages?' "$([[ -n "$HERMES_ADDON_PYTHON_VERSION" ]] && echo true || echo false)"; then
    while true; do
      HERMES_ADDON_PYTHON_VERSION="$(prompt_value 'Python version for addon packages' "$(answer_default HERMES_ADDON_PYTHON_VERSION 3.13)")"
      [[ "$HERMES_ADDON_PYTHON_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] && break
      printf 'Enter a Python version such as 3.13 or 3.13.5.\n' >&2
    done
  else
    HERMES_ADDON_PYTHON_VERSION=
  fi

  bootstrap_overwrite_default=false
  [[ "${HERMES_BOOTSTRAP_MODE:-}" == overwrite ]] && bootstrap_overwrite_default=true
  if ask_yes_no 'Overwrite existing bootstrap-managed files on the PVC?' "$bootstrap_overwrite_default"; then
    HERMES_BOOTSTRAP_MODE=overwrite
  else
    HERMES_BOOTSTRAP_MODE=missing
  fi
fi

: "${HERMES_NAMESPACE:?missing HERMES_NAMESPACE in answers}"
: "${HERMES_BOOTSTRAP_PROFILE:?missing HERMES_BOOTSTRAP_PROFILE in answers}"
: "${HERMES_DASHBOARD_ENABLED:?missing HERMES_DASHBOARD_ENABLED in answers}"
: "${HERMES_WEBUI_ENABLED:?missing HERMES_WEBUI_ENABLED in answers}"
: "${HERMES_BROWSER_ENABLED:?missing HERMES_BROWSER_ENABLED in answers}"
: "${HERMES_ANSIBLE_SETUP:?missing HERMES_ANSIBLE_SETUP in answers}"
: "${HERMES_SSH_SETUP:?missing HERMES_SSH_SETUP in answers}"
: "${HERMES_BOOTSTRAP_MODE:?missing HERMES_BOOTSTRAP_MODE in answers}"
WEBUI_HOST="${WEBUI_HOST:-}"
DASHBOARD_HOST="${DASHBOARD_HOST:-}"
DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER:-}"
DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD:-}"
HERMES_ANSIBLE_VERSION="${HERMES_ANSIBLE_VERSION:-}"
HERMES_NPX_SETUP="${HERMES_NPX_SETUP:-}"
HERMES_ADDON_PYTHON_VERSION="${HERMES_ADDON_PYTHON_VERSION:-}"
MODEL_PROVIDER="${MODEL_PROVIDER:-openai-codex}"
MODEL_NAME="${MODEL_NAME:-gpt-5.6-luna}"
HERMES_AGENT_IMAGE="${HERMES_AGENT_IMAGE:-nousresearch/hermes-agent:latest}"
HERMES_WEBUI_IMAGE="${HERMES_WEBUI_IMAGE:-ghcr.io/nesquena/hermes-webui:latest}"
HERMES_BROWSER_IMAGE="${HERMES_BROWSER_IMAGE:-ghcr.io/browserless/chromium:latest}"
HERMES_IMAGE_PULL_POLICY="${HERMES_IMAGE_PULL_POLICY:-IfNotPresent}"
[[ "$MODEL_PROVIDER" =~ ^[A-Za-z0-9._:/-]+$ ]] || { printf 'ERROR: invalid model provider.\n' >&2; exit 1; }
[[ "$MODEL_NAME" =~ ^[A-Za-z0-9._:/-]+$ ]] || { printf 'ERROR: invalid model name.\n' >&2; exit 1; }
for image in "$HERMES_AGENT_IMAGE" "$HERMES_WEBUI_IMAGE" "$HERMES_BROWSER_IMAGE"; do
  [[ "$image" =~ ^[A-Za-z0-9._/@:-]+$ ]] || { printf 'ERROR: invalid container image reference.\n' >&2; exit 1; }
done
[[ "$HERMES_IMAGE_PULL_POLICY" == IfNotPresent || "$HERMES_IMAGE_PULL_POLICY" == Always ]] || { printf 'ERROR: invalid image pull policy.\n' >&2; exit 1; }
[[ "$HERMES_BOOTSTRAP_MODE" == missing || "$HERMES_BOOTSTRAP_MODE" == overwrite ]] || { printf 'ERROR: invalid bootstrap mode in answers.\n' >&2; exit 1; }
if [[ "$HERMES_ANSIBLE_SETUP" == true ]]; then
  [[ "$HERMES_ANSIBLE_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || { printf 'ERROR: invalid Ansible version in answers.\n' >&2; exit 1; }
  HERMES_SSH_SETUP=true
fi

# Resolve remaining profile defaults not set by wizard questions.
# This fills HERMES_NPX_SETUP and any other future profile-owned
# variables while preserving the wizard's explicit choices.
export HERMES_BOOTSTRAP_PROFILE
apply_profile_defaults "$HERMES_BOOTSTRAP_PROFILE"

CONFIG_MARKER="$CONFIG_DIR/.hermes-current-config"
if [[ -e "$CONFIG_DIR" && -n "$(find "$CONFIG_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  if [[ "$FROM_ANSWERS" == true ]]; then
    [[ -f "$CONFIG_MARKER" ]] || {
      printf 'ERROR: refusing to replace unowned directory without %s\n' "$CONFIG_MARKER" >&2
      exit 1
    }
    rm -rf "$CONFIG_DIR"
  else
    ask_yes_no "Replace existing configuration in $CONFIG_DIR?" false || { printf 'Configuration cancelled.\n'; exit 0; }
    rm -rf "$CONFIG_DIR"
  fi
fi
mkdir -p "$CONFIG_DIR/artifacts" "$CONFIG_DIR/bootstrap"
chmod 700 "$CONFIG_DIR" "$CONFIG_DIR/artifacts" "$CONFIG_DIR/bootstrap"
: > "$CONFIG_MARKER"
chmod 600 "$CONFIG_MARKER"

# Reuse canonical profile composition so setup cannot drift from install.sh.
RENDER_DIR="$CONFIG_DIR/artifacts"
export HERMES_BOOTSTRAP_PROFILE HERMES_ANSIBLE_SETUP HERMES_SSH_SETUP
compose_profile_bootstrap "$HERMES_BOOTSTRAP_PROFILE"
cp -a "$HERMES_BOOTSTRAP_DIR"/. "$CONFIG_DIR/bootstrap"/
rm -rf "$RENDER_DIR/bootstrap-profile"
HERMES_BOOTSTRAP_DIR="$CONFIG_DIR/bootstrap"
HERMES_RENDER_DIR="$CONFIG_DIR/artifacts"

# Deliver Agent-native configuration through the existing bootstrap path to the
# persistent /opt/data/config.yaml file.
cat > "$HERMES_BOOTSTRAP_DIR/config.yaml" <<EOF
provider: $MODEL_PROVIDER
model: $MODEL_NAME
agent:
  verify_on_stop: false
terminal:
  cwd: /workspace
display:
  tool_progress: all
gateway:
  host: 0.0.0.0
  port: 8642
EOF
chmod 600 "$HERMES_BOOTSTRAP_DIR/config.yaml"

ENV_OUT="$CONFIG_DIR/hermes.env"
umask 077
: > "$ENV_OUT"
write_setting "$ENV_OUT" HERMES_NAMESPACE "$HERMES_NAMESPACE"
write_setting "$ENV_OUT" HERMES_AGENT_ENABLED true
write_setting "$ENV_OUT" HERMES_DASHBOARD_ENABLED "$HERMES_DASHBOARD_ENABLED"
write_setting "$ENV_OUT" HERMES_WEBUI_ENABLED "$HERMES_WEBUI_ENABLED"
write_setting "$ENV_OUT" HERMES_BROWSER_ENABLED "$HERMES_BROWSER_ENABLED"
write_setting "$ENV_OUT" WEBUI_HOST "$WEBUI_HOST"
write_setting "$ENV_OUT" DASHBOARD_HOST "$DASHBOARD_HOST"
write_setting "$ENV_OUT" DASHBOARD_AUTH_USER "$DASHBOARD_AUTH_USER"
write_setting "$ENV_OUT" MODEL_PROVIDER "$MODEL_PROVIDER"
write_setting "$ENV_OUT" MODEL_NAME "$MODEL_NAME"
write_setting "$ENV_OUT" HERMES_AGENT_IMAGE "$HERMES_AGENT_IMAGE"
write_setting "$ENV_OUT" HERMES_WEBUI_IMAGE "$HERMES_WEBUI_IMAGE"
write_setting "$ENV_OUT" HERMES_BROWSER_IMAGE "$HERMES_BROWSER_IMAGE"
write_setting "$ENV_OUT" HERMES_IMAGE_PULL_POLICY "$HERMES_IMAGE_PULL_POLICY"
write_setting "$ENV_OUT" HERMES_BOOTSTRAP_PROFILE "$HERMES_BOOTSTRAP_PROFILE"
write_setting "$ENV_OUT" HERMES_BOOTSTRAP_DIR "$HERMES_BOOTSTRAP_DIR"
write_setting "$ENV_OUT" HERMES_BOOTSTRAP_MODE "$HERMES_BOOTSTRAP_MODE"
write_setting "$ENV_OUT" HERMES_RENDER_DIR "$HERMES_RENDER_DIR"
write_setting "$ENV_OUT" HERMES_ANSIBLE_SETUP "$HERMES_ANSIBLE_SETUP"
write_setting "$ENV_OUT" HERMES_NPX_SETUP "$HERMES_NPX_SETUP"
write_setting "$ENV_OUT" HERMES_ADDON_PYTHON_VERSION "$HERMES_ADDON_PYTHON_VERSION"
write_setting "$ENV_OUT" HERMES_ANSIBLE_VERSION "$HERMES_ANSIBLE_VERSION"
write_setting "$ENV_OUT" HERMES_SSH_SETUP "$HERMES_SSH_SETUP"
write_setting "$ENV_OUT" HERMES_SSH_GENERATE_KEY "$HERMES_SSH_SETUP"
chmod 600 "$ENV_OUT"

if [[ "$FROM_ANSWERS" != true ]]; then
  : > "$ANSWERS_FILE"
  write_setting "$ANSWERS_FILE" HERMES_NAMESPACE "$HERMES_NAMESPACE"
  write_setting "$ANSWERS_FILE" HERMES_BOOTSTRAP_PROFILE "$HERMES_BOOTSTRAP_PROFILE"
  write_setting "$ANSWERS_FILE" HERMES_DASHBOARD_ENABLED "$HERMES_DASHBOARD_ENABLED"
  write_setting "$ANSWERS_FILE" HERMES_WEBUI_ENABLED "$HERMES_WEBUI_ENABLED"
  write_setting "$ANSWERS_FILE" HERMES_BROWSER_ENABLED "$HERMES_BROWSER_ENABLED"
  write_setting "$ANSWERS_FILE" WEBUI_HOST "$WEBUI_HOST"
  write_setting "$ANSWERS_FILE" DASHBOARD_HOST "$DASHBOARD_HOST"
  write_setting "$ANSWERS_FILE" DASHBOARD_AUTH_USER "$DASHBOARD_AUTH_USER"
  write_setting "$ANSWERS_FILE" MODEL_PROVIDER "$MODEL_PROVIDER"
  write_setting "$ANSWERS_FILE" MODEL_NAME "$MODEL_NAME"
  write_setting "$ANSWERS_FILE" HERMES_AGENT_IMAGE "$HERMES_AGENT_IMAGE"
  write_setting "$ANSWERS_FILE" HERMES_WEBUI_IMAGE "$HERMES_WEBUI_IMAGE"
  write_setting "$ANSWERS_FILE" HERMES_BROWSER_IMAGE "$HERMES_BROWSER_IMAGE"
  write_setting "$ANSWERS_FILE" HERMES_IMAGE_PULL_POLICY "$HERMES_IMAGE_PULL_POLICY"
  write_setting "$ANSWERS_FILE" HERMES_ANSIBLE_SETUP "$HERMES_ANSIBLE_SETUP"
  write_setting "$ANSWERS_FILE" HERMES_NPX_SETUP "$HERMES_NPX_SETUP"
  write_setting "$ANSWERS_FILE" HERMES_ADDON_PYTHON_VERSION "$HERMES_ADDON_PYTHON_VERSION"
  write_setting "$ANSWERS_FILE" HERMES_ANSIBLE_VERSION "$HERMES_ANSIBLE_VERSION"
  write_setting "$ANSWERS_FILE" HERMES_SSH_SETUP "$HERMES_SSH_SETUP"
  write_setting "$ANSWERS_FILE" HERMES_BOOTSTRAP_MODE "$HERMES_BOOTSTRAP_MODE"
  chmod 600 "$ANSWERS_FILE"
fi

printf '\nConfiguration created.\n'
printf '  Directory:  %s\n' "$CONFIG_DIR"
printf '  Environment: %s (mode 600)\n' "$ENV_OUT"
printf '  Bootstrap:   %s (%s mode)\n' "$HERMES_BOOTSTRAP_DIR" "$HERMES_BOOTSTRAP_MODE"
printf '  Agent config: %s -> /opt/data/config.yaml\n' "$HERMES_BOOTSTRAP_DIR/config.yaml"
printf '  Artifacts:   %s\n' "$HERMES_RENDER_DIR"
printf '  Credentials: Kubernetes Secrets only; values are not stored locally or printed\n'
printf '  Answers:     %s (mode 600)\n' "$ANSWERS_FILE"
printf '  Components:  agent%s%s%s\n' \
  "$([[ "$HERMES_DASHBOARD_ENABLED" == true ]] && printf ', dashboard')" \
  "$([[ "$HERMES_WEBUI_ENABLED" == true ]] && printf ', webui')" \
  "$([[ "$HERMES_BROWSER_ENABLED" == true ]] && printf ', browser')"
printf '  Ansible:     %s%s\n' "$HERMES_ANSIBLE_SETUP" "$([[ "$HERMES_ANSIBLE_SETUP" == true ]] && printf ' (%s)' "$HERMES_ANSIBLE_VERSION")"
printf '  SSH keys:    %s\n\n' "$HERMES_SSH_SETUP"

installer_cmd="HERMES_INSTALL_LIB_ONLY=false ENV_FILE=$(printf '%q' "$ENV_OUT") $(printf '%q' "$ROOT_DIR/install.sh")"
if [[ "$RUN_INSTALLER" == true ]] && ask_yes_no 'Run install.sh now?' false; then
  HERMES_INSTALL_LIB_ONLY=false ENV_FILE="$ENV_OUT" DASHBOARD_AUTH_PASSWORD="$DASHBOARD_AUTH_PASSWORD" "$ROOT_DIR/install.sh"
else
  printf 'Run the installer with:\n  %s\n' "$installer_cmd"
fi
