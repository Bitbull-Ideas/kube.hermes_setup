#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ENV_FILE="$ROOT_DIR/hermes.env"
if [[ ! -f "$DEFAULT_ENV_FILE" && -f "$ROOT_DIR/current_config/hermes.env" ]]; then
  DEFAULT_ENV_FILE="$ROOT_DIR/current_config/hermes.env"
fi
ENV_FILE="${ENV_FILE:-$DEFAULT_ENV_FILE}"
RENDER_DIR="${HERMES_RENDER_DIR:-$ROOT_DIR/.rendered}"
MANIFEST_OUT="$RENDER_DIR/hermes.yaml"
BOOTSTRAP_ARCHIVE="$RENDER_DIR/bootstrap.tar.gz"
BOOTSTRAP_STAGE="$RENDER_DIR/bootstrap-stage"
# Explicit credential values from the process environment take precedence over
# blank or different values loaded from the selected env file.
PROCESS_DASHBOARD_AUTH_USER_SET="${DASHBOARD_AUTH_USER+x}"
PROCESS_DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER-}"
PROCESS_DASHBOARD_AUTH_PASSWORD_SET="${DASHBOARD_AUTH_PASSWORD+x}"
PROCESS_DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD-}"
PROCESS_API_SERVER_KEY_SET="${API_SERVER_KEY+x}"
PROCESS_API_SERVER_KEY="${API_SERVER_KEY-}"
PROCESS_BROWSER_TOKEN_SET="${BROWSER_TOKEN+x}"
PROCESS_BROWSER_TOKEN="${BROWSER_TOKEN-}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
rand_hex() { openssl rand -hex "${1:-32}"; }

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    warn "Missing env file: $ENV_FILE. Using environment variables only."
    return 0
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  [[ -z "$PROCESS_DASHBOARD_AUTH_USER_SET" ]] || DASHBOARD_AUTH_USER="$PROCESS_DASHBOARD_AUTH_USER"
  [[ -z "$PROCESS_DASHBOARD_AUTH_PASSWORD_SET" ]] || DASHBOARD_AUTH_PASSWORD="$PROCESS_DASHBOARD_AUTH_PASSWORD"
  [[ -z "$PROCESS_API_SERVER_KEY_SET" ]] || API_SERVER_KEY="$PROCESS_API_SERVER_KEY"
  [[ -z "$PROCESS_BROWSER_TOKEN_SET" ]] || BROWSER_TOKEN="$PROCESS_BROWSER_TOKEN"
}

prepare_paths() {
  RENDER_DIR="${HERMES_RENDER_DIR:-$ROOT_DIR/.rendered}"
  MANIFEST_OUT="$RENDER_DIR/hermes.yaml"
  BOOTSTRAP_ARCHIVE="$RENDER_DIR/bootstrap.tar.gz"
  BOOTSTRAP_STAGE="$RENDER_DIR/bootstrap-stage"
}

is_truthy() {
  [[ "${1:-}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]
}

read_existing_secret_value() {
  local secret="$1" key="$2" name encoded decoded
  if ! name="$(kubectl -n "$HERMES_NAMESPACE" get secret "$secret" --ignore-not-found -o jsonpath='{.metadata.name}')"; then
    warn "Unable to inspect Kubernetes Secret $secret"
    return 2
  fi
  [[ -n "$name" ]] || return 1
  if ! encoded="$(kubectl -n "$HERMES_NAMESPACE" get secret "$secret" -o "jsonpath={.data['$key']}")"; then
    warn "Unable to read Kubernetes Secret $secret key $key"
    return 2
  fi
  [[ -n "$encoded" ]] || {
    warn "Kubernetes Secret $secret is missing required key $key"
    return 2
  }
  if (( ${#encoded} % 4 != 0 )) || [[ ! "$encoded" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
    warn "Kubernetes Secret $secret key $key is malformed or empty"
    return 2
  fi
  if ! decoded="$(printf '%s' "$encoded" | openssl base64 -d -A 2>/dev/null)" || [[ -z "$decoded" ]]; then
    warn "Kubernetes Secret $secret key $key is malformed or empty"
    return 2
  fi
  printf '%s' "$decoded"
}

resolve_runtime_credentials() {
  local namespace_exists existing status need_lookup=false
  local dashboard_enabled="${HERMES_DASHBOARD_ENABLED:-true}"
  local webui_enabled="${HERMES_WEBUI_ENABLED:-true}"
  local browser_enabled="${HERMES_BROWSER_ENABLED:-true}"
  CREDENTIAL_SOURCE_DASHBOARD="explicit"
  CREDENTIAL_SOURCE_API="explicit"
  CREDENTIAL_SOURCE_BROWSER="explicit"

  [[ -n "${DASHBOARD_AUTH_PASSWORD:-}" ]] || CREDENTIAL_SOURCE_DASHBOARD=""
  [[ -n "${API_SERVER_KEY:-}" ]] || CREDENTIAL_SOURCE_API=""
  [[ -n "${BROWSER_TOKEN:-}" ]] || CREDENTIAL_SOURCE_BROWSER=""

  if { is_truthy "$dashboard_enabled" || is_truthy "$webui_enabled"; } && [[ -z "${DASHBOARD_AUTH_PASSWORD:-}" ]]; then
    need_lookup=true
  fi
  [[ -n "${API_SERVER_KEY:-}" ]] || need_lookup=true
  if is_truthy "$browser_enabled" && [[ -z "${BROWSER_TOKEN:-}" ]]; then
    need_lookup=true
  fi

  if [[ "$need_lookup" == false ]]; then
    [[ ${#API_SERVER_KEY} -ge 16 ]] || fail "API_SERVER_KEY must be at least 16 characters"
    if is_truthy "$browser_enabled"; then
      BROWSER_CDP_URL="ws://hermes-browser:3000/chromium?token=${BROWSER_TOKEN}"
    else
      BROWSER_CDP_URL=""
    fi
    export DASHBOARD_AUTH_USER DASHBOARD_AUTH_PASSWORD API_SERVER_KEY BROWSER_TOKEN BROWSER_CDP_URL
    return 0
  fi

  require_cmd kubectl
  require_cmd openssl
  if ! namespace_exists="$(kubectl get namespace "$HERMES_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}')"; then
    fail "Unable to inspect namespace $HERMES_NAMESPACE; refusing to generate replacement credentials"
  fi

  if [[ -n "$namespace_exists" ]]; then
    if [[ -z "${DASHBOARD_AUTH_PASSWORD:-}" ]] && { is_truthy "$dashboard_enabled" || is_truthy "$webui_enabled"; }; then
      status=0
      existing="$(read_existing_secret_value hermes-dashboard-auth password)" || status=$?
      case "$status" in
        0) DASHBOARD_AUTH_PASSWORD="$existing"; CREDENTIAL_SOURCE_DASHBOARD=reused ;;
        1) DASHBOARD_AUTH_PASSWORD="$(rand_hex 18)"; CREDENTIAL_SOURCE_DASHBOARD=generated ;;
        *) fail "Unable to safely resolve Dashboard/WebUI credentials" ;;
      esac
      if [[ "${DASHBOARD_AUTH_USER_EXPLICIT:-false}" != true && "$CREDENTIAL_SOURCE_DASHBOARD" == reused ]]; then
        status=0
        existing="$(read_existing_secret_value hermes-dashboard-auth username)" || status=$?
        [[ "$status" -eq 0 ]] || fail "Unable to safely reuse Dashboard/WebUI username"
        DASHBOARD_AUTH_USER="$existing"
      fi
    fi
    if [[ -z "${API_SERVER_KEY:-}" ]]; then
      status=0
      existing="$(read_existing_secret_value hermes-api-server api-key)" || status=$?
      case "$status" in
        0) API_SERVER_KEY="$existing"; CREDENTIAL_SOURCE_API=reused ;;
        1) API_SERVER_KEY="$(rand_hex 32)"; CREDENTIAL_SOURCE_API=generated ;;
        *) fail "Unable to safely resolve API server key" ;;
      esac
    fi
    if is_truthy "$browser_enabled" && [[ -z "${BROWSER_TOKEN:-}" ]]; then
      status=0
      existing="$(read_existing_secret_value hermes-browser-token token)" || status=$?
      case "$status" in
        0) BROWSER_TOKEN="$existing"; CREDENTIAL_SOURCE_BROWSER=reused ;;
        1) BROWSER_TOKEN="$(rand_hex 32)"; CREDENTIAL_SOURCE_BROWSER=generated ;;
        *) fail "Unable to safely resolve Browserless token" ;;
      esac
    fi
  else
    if [[ -z "${DASHBOARD_AUTH_PASSWORD:-}" ]] && { is_truthy "$dashboard_enabled" || is_truthy "$webui_enabled"; }; then
      DASHBOARD_AUTH_PASSWORD="$(rand_hex 18)"
      CREDENTIAL_SOURCE_DASHBOARD=generated
    fi
    if [[ -z "${API_SERVER_KEY:-}" ]]; then
      API_SERVER_KEY="$(rand_hex 32)"
      CREDENTIAL_SOURCE_API=generated
    fi
    if is_truthy "$browser_enabled"; then
      if [[ -z "${BROWSER_TOKEN:-}" ]]; then
        BROWSER_TOKEN="$(rand_hex 32)"
        CREDENTIAL_SOURCE_BROWSER=generated
      fi
    else
      BROWSER_TOKEN=""
    fi
  fi

  [[ ${#API_SERVER_KEY} -ge 16 ]] || fail "API_SERVER_KEY must be at least 16 characters"
  if is_truthy "$browser_enabled"; then
    BROWSER_CDP_URL="ws://hermes-browser:3000/chromium?token=${BROWSER_TOKEN}"
  else
    BROWSER_CDP_URL=""
  fi
  export DASHBOARD_AUTH_USER DASHBOARD_AUTH_PASSWORD API_SERVER_KEY BROWSER_TOKEN BROWSER_CDP_URL
}

enabled_deployments() {
  printf '%s\n' hermes-agent
  is_truthy "$HERMES_DASHBOARD_ENABLED" && printf '%s\n' hermes-dashboard
  is_truthy "$HERMES_WEBUI_ENABLED" && printf '%s\n' hermes-webui
  is_truthy "$HERMES_BROWSER_ENABLED" && printf '%s\n' hermes-browser
}

validate() {
  require_cmd kubectl
  require_cmd openssl
  [[ -n "${HERMES_NAMESPACE:-}" ]] || fail "HERMES_NAMESPACE is required"
  is_truthy "$HERMES_AGENT_ENABLED" || fail "HERMES_AGENT_ENABLED must remain true; the Agent is mandatory"
  if is_truthy "$HERMES_WEBUI_ENABLED"; then
    [[ -n "${WEBUI_HOST:-}" ]] || fail "WEBUI_HOST is required when WebUI is enabled"
    [[ "$WEBUI_HOST" != *example.com ]] || warn "WEBUI_HOST still uses example.com"
  fi
  if is_truthy "$HERMES_DASHBOARD_ENABLED"; then
    [[ -n "${DASHBOARD_HOST:-}" ]] || fail "DASHBOARD_HOST is required when Dashboard is enabled"
    [[ "$DASHBOARD_HOST" != *example.com ]] || warn "DASHBOARD_HOST still uses example.com"
  fi
}

prepare_defaults() {
  # Internal state from a previous sourced/library run must never influence the
  # current requirements selection.
  unset HERMES_PROFILE_REQUIREMENTS_SELECTED
  export HERMES_BOOTSTRAP_PROFILE="${HERMES_BOOTSTRAP_PROFILE-personal-assistant}"
  apply_profile_defaults "$HERMES_BOOTSTRAP_PROFILE"
  export HERMES_AGENT_ENABLED="${HERMES_AGENT_ENABLED:-true}"
  export HERMES_DASHBOARD_ENABLED="${HERMES_DASHBOARD_ENABLED:-true}"
  export HERMES_WEBUI_ENABLED="${HERMES_WEBUI_ENABLED:-true}"
  export HERMES_BROWSER_ENABLED="${HERMES_BROWSER_ENABLED:-true}"
  export HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
  export INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-traefik}"
  export TRAEFIK_ENTRYPOINT="${TRAEFIK_ENTRYPOINT:-websecure}"
  export TLS_ENABLED="${TLS_ENABLED:-true}"
  export TLS_SECRET_NAME="${TLS_SECRET_NAME:-}"
  export HERMES_AGENT_IMAGE="${HERMES_AGENT_IMAGE:-nousresearch/hermes-agent:latest}"
  export HERMES_WEBUI_IMAGE="${HERMES_WEBUI_IMAGE:-ghcr.io/nesquena/hermes-webui:latest}"
  export HERMES_BROWSER_IMAGE="${HERMES_BROWSER_IMAGE:-ghcr.io/browserless/chromium:latest}"
  export HERMES_HOME_STORAGE_SIZE="${HERMES_HOME_STORAGE_SIZE:-10Gi}"
  export HERMES_WORKSPACE_STORAGE_SIZE="${HERMES_WORKSPACE_STORAGE_SIZE:-20Gi}"
  export HERMES_RUNTIME_UID="${HERMES_RUNTIME_UID:-10000}"
  export HERMES_RUNTIME_GID="${HERMES_RUNTIME_GID:-10000}"
  export HERMES_WEBUI_MAX_UPLOAD_MB="${HERMES_WEBUI_MAX_UPLOAD_MB:-220}"
  export HERMES_BOOTSTRAP_DIR="${HERMES_BOOTSTRAP_DIR:-}"
  export HERMES_BOOTSTRAP_MODE="${HERMES_BOOTSTRAP_MODE:-missing}"
  export HERMES_BOOTSTRAP_INCLUDE_AUTH="${HERMES_BOOTSTRAP_INCLUDE_AUTH:-false}"
  export HERMES_ADDON_REQUIREMENTS="${HERMES_ADDON_REQUIREMENTS:-}"
  # Hard-coded addon runtime facts. Keep these out of hermes.env examples unless the chart changes.
  export HERMES_ADDON_PYTHON_MODE="uv"
  export HERMES_UV_DIR="/opt/data/uv"
  export HERMES_ADDON_VENV="/opt/data/addon-venv"
  export HERMES_ADDON_PYTHON_VERSION="${HERMES_ADDON_PYTHON_VERSION:-3.13}"
  export HERMES_ANSIBLE_SETUP="${HERMES_ANSIBLE_SETUP:-false}"
  export HERMES_ANSIBLE_VERSION="${HERMES_ANSIBLE_VERSION:-14.1.0}"
  if is_truthy "$HERMES_ANSIBLE_SETUP"; then
    export HERMES_SSH_SETUP=true
  fi
  if [[ -z "${HERMES_ANSIBLE_CONFIG+x}" ]]; then
    if [[ "$HERMES_ANSIBLE_SETUP" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
      export HERMES_ANSIBLE_CONFIG="/workspace/ansible/ansible.cfg"
    else
      export HERMES_ANSIBLE_CONFIG=""
    fi
  fi
  export HERMES_SSH_SETUP="${HERMES_SSH_SETUP:-true}"
  export HERMES_SSH_GENERATE_KEY="${HERMES_SSH_GENERATE_KEY:-${HERMES_SSH_SETUP}}"
  export HERMES_SSH_KEY_TYPE="${HERMES_SSH_KEY_TYPE:-ed25519}"
  export HERMES_SSH_KEY_PATH="${HERMES_SSH_KEY_PATH:-/opt/data/.ssh/id_ed25519}"
  export HERMES_AGENT_CPU_REQUEST="${HERMES_AGENT_CPU_REQUEST:-100m}"
  export HERMES_AGENT_MEMORY_REQUEST="${HERMES_AGENT_MEMORY_REQUEST:-256Mi}"
  export HERMES_AGENT_CPU_LIMIT="${HERMES_AGENT_CPU_LIMIT:-1}"
  export HERMES_AGENT_MEMORY_LIMIT="${HERMES_AGENT_MEMORY_LIMIT:-1Gi}"
  export HERMES_DASHBOARD_CPU_REQUEST="${HERMES_DASHBOARD_CPU_REQUEST:-100m}"
  export HERMES_DASHBOARD_MEMORY_REQUEST="${HERMES_DASHBOARD_MEMORY_REQUEST:-96Mi}"
  export HERMES_DASHBOARD_CPU_LIMIT="${HERMES_DASHBOARD_CPU_LIMIT:-1}"
  export HERMES_DASHBOARD_MEMORY_LIMIT="${HERMES_DASHBOARD_MEMORY_LIMIT:-1Gi}"
  export HERMES_WEBUI_CPU_REQUEST="${HERMES_WEBUI_CPU_REQUEST:-100m}"
  export HERMES_WEBUI_MEMORY_REQUEST="${HERMES_WEBUI_MEMORY_REQUEST:-256Mi}"
  export HERMES_WEBUI_CPU_LIMIT="${HERMES_WEBUI_CPU_LIMIT:-1}"
  export HERMES_WEBUI_MEMORY_LIMIT="${HERMES_WEBUI_MEMORY_LIMIT:-1Gi}"
  export HERMES_BROWSER_CPU_REQUEST="${HERMES_BROWSER_CPU_REQUEST:-100m}"
  export HERMES_BROWSER_MEMORY_REQUEST="${HERMES_BROWSER_MEMORY_REQUEST:-128Mi}"
  export HERMES_BROWSER_CPU_LIMIT="${HERMES_BROWSER_CPU_LIMIT:-1}"
  export HERMES_BROWSER_MEMORY_LIMIT="${HERMES_BROWSER_MEMORY_LIMIT:-1Gi}"
  export STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-}"
  export MODEL_PROVIDER="${MODEL_PROVIDER:-codex}"
  export MODEL_NAME="${MODEL_NAME:-gpt-5.6-luna}"
  if is_truthy "$HERMES_DASHBOARD_ENABLED" || is_truthy "$HERMES_WEBUI_ENABLED"; then
    if [[ -n "${DASHBOARD_AUTH_USER:-}" ]]; then
      export DASHBOARD_AUTH_USER_EXPLICIT=true
    else
      export DASHBOARD_AUTH_USER_EXPLICIT=false
    fi
    export DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER:-admin}"
    export DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD:-}"
  else
    export DASHBOARD_AUTH_USER=""
    export DASHBOARD_AUTH_PASSWORD=""
  fi
  export API_SERVER_KEY="${API_SERVER_KEY:-}"
  if is_truthy "$HERMES_BROWSER_ENABLED"; then
    export BROWSER_TOKEN="${BROWSER_TOKEN:-}"
  else
    export BROWSER_TOKEN=""
  fi
  export BROWSER_CONCURRENT="${BROWSER_CONCURRENT:-4}"
  export BROWSER_QUEUED="${BROWSER_QUEUED:-10}"
  export BROWSER_TIMEOUT_MS="${BROWSER_TIMEOUT_MS:-30000}"
  [[ "$BROWSER_CONCURRENT" =~ ^[0-9]+$ ]] || fail "BROWSER_CONCURRENT must be numeric"
  [[ "$BROWSER_QUEUED" =~ ^[0-9]+$ ]] || fail "BROWSER_QUEUED must be numeric"
  [[ "$BROWSER_TIMEOUT_MS" =~ ^[0-9]+$ ]] || fail "BROWSER_TIMEOUT_MS must be numeric"
  if (( BROWSER_CONCURRENT < 4 )); then
    warn "BROWSER_CONCURRENT=$BROWSER_CONCURRENT is below the repo default 4; parallel WebUI screenshot/browser workflows can queue and time out during CDP handshakes."
  fi
  if is_truthy "$HERMES_BROWSER_ENABLED"; then
    export BROWSER_CDP_URL=""
  else
    export BROWSER_CDP_URL=""
  fi
  case "$HERMES_BOOTSTRAP_MODE" in
    disabled|missing|overwrite) ;;
    *) fail "HERMES_BOOTSTRAP_MODE must be one of: disabled, missing, overwrite" ;;
  esac
  if [[ -n "$HERMES_BOOTSTRAP_DIR" && "$HERMES_BOOTSTRAP_MODE" != "disabled" ]]; then
    require_cmd tar
    [[ -d "$HERMES_BOOTSTRAP_DIR" ]] || fail "HERMES_BOOTSTRAP_DIR does not exist or is not a directory: $HERMES_BOOTSTRAP_DIR"
  fi
  if [[ -z "$HERMES_BOOTSTRAP_DIR" && -n "$HERMES_BOOTSTRAP_PROFILE" && "$HERMES_BOOTSTRAP_MODE" != "disabled" ]]; then
    require_cmd tar
    compose_profile_bootstrap "$HERMES_BOOTSTRAP_PROFILE"
  fi
  if [[ -n "$HERMES_ADDON_REQUIREMENTS" ]]; then
    require_cmd tar
    [[ -f "$HERMES_ADDON_REQUIREMENTS" ]] || fail "HERMES_ADDON_REQUIREMENTS does not exist or is not a file: $HERMES_ADDON_REQUIREMENTS"
  fi
  [[ "$HERMES_ADDON_PYTHON_MODE" = "uv" ]] || fail "HERMES_ADDON_PYTHON_MODE is fixed to uv"
  [[ "$HERMES_UV_DIR" = /opt/data/* ]] || fail "HERMES_UV_DIR must be under /opt/data for PVC persistence"
  [[ "$HERMES_ADDON_VENV" = /opt/data/* ]] || fail "HERMES_ADDON_VENV must be under /opt/data for PVC persistence"
  [[ "$HERMES_ADDON_PYTHON_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "HERMES_ADDON_PYTHON_VERSION must look like 3.13 or 3.13.5"
  case "$HERMES_SSH_SETUP" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) fail "HERMES_SSH_SETUP must be boolean" ;; esac
  case "$HERMES_ANSIBLE_SETUP" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) fail "HERMES_ANSIBLE_SETUP must be boolean" ;; esac
  for component_value in "$HERMES_AGENT_ENABLED" "$HERMES_DASHBOARD_ENABLED" "$HERMES_WEBUI_ENABLED" "$HERMES_BROWSER_ENABLED"; do
    case "$component_value" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) fail "component enablement values must be boolean" ;; esac
  done
  if is_truthy "$HERMES_ANSIBLE_SETUP"; then
    [[ "$HERMES_ANSIBLE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "HERMES_ANSIBLE_VERSION must look like 14.1.0"
  fi
  case "$HERMES_SSH_GENERATE_KEY" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) fail "HERMES_SSH_GENERATE_KEY must be boolean" ;; esac
  case "$HERMES_SSH_KEY_TYPE" in ed25519|rsa|ecdsa) ;; *) fail "HERMES_SSH_KEY_TYPE must be one of: ed25519, rsa, ecdsa" ;; esac
  [[ "$HERMES_SSH_KEY_PATH" = /opt/data/.ssh/* ]] || fail "HERMES_SSH_KEY_PATH must be under /opt/data/.ssh for PVC persistence"
  [[ "$HERMES_RUNTIME_UID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_UID must be numeric"
  [[ "$HERMES_RUNTIME_GID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_GID must be numeric"
  [[ "$HERMES_WEBUI_MAX_UPLOAD_MB" =~ ^[0-9]+$ ]] || fail "HERMES_WEBUI_MAX_UPLOAD_MB must be numeric"
}

bootstrap_enabled() {
  [[ -n "${HERMES_BOOTSTRAP_DIR:-}" && "${HERMES_BOOTSTRAP_MODE:-disabled}" != "disabled" ]]
}

addon_requirements_enabled() {
  [[ -n "${HERMES_ADDON_REQUIREMENTS:-}" ]]
}

apply_profile_defaults() {
  [[ -n "$HERMES_BOOTSTRAP_PROFILE" ]] || return 0
  local prof="$1"
  local profiledir="$ROOT_DIR/examples/bootstrap-profiles/$prof"
  [[ -d "$profiledir" ]] || fail "Unknown bootstrap profile: $prof. Available profiles: $(cd "$ROOT_DIR/examples/bootstrap-profiles" 2>/dev/null && printf '%s ' */ | tr -d '/')"
  local defaults="$profiledir/defaults.conf"
  [[ -f "$defaults" ]] || fail "Profile $prof is missing defaults.conf"
  # defaults.conf is repository-controlled and may define only HERMES_PROFILE_DEFAULT_* values.
  if grep -Ev '^[[:space:]]*(#.*|$|HERMES_PROFILE_DEFAULT_[A-Z0-9_]+=[^[:space:]]*)$' "$defaults" | grep -q .; then
    fail "Profile $prof has invalid entries in defaults.conf"
  fi
  # shellcheck disable=SC1090
  source "$defaults"
  if [[ -z "${HERMES_SSH_SETUP+x}" ]]; then
    export HERMES_SSH_SETUP="${HERMES_PROFILE_DEFAULT_SSH_SETUP:-true}"
  fi
  if [[ -z "${HERMES_ANSIBLE_SETUP+x}" ]]; then
    export HERMES_ANSIBLE_SETUP="${HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP:-false}"
  fi
  if [[ -z "${HERMES_ADDON_REQUIREMENTS+x}" && -n "${HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS:-}" ]]; then
    export HERMES_ADDON_REQUIREMENTS="$profiledir/$HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS"
    export HERMES_PROFILE_REQUIREMENTS_SELECTED=true
  fi
}

compose_profile_bootstrap() {
  local prof="$1"
  local shared="$ROOT_DIR/examples/bootstrap-shared"
  local shared_skills="$shared/skills"
  local profiledir="$ROOT_DIR/examples/bootstrap-profiles/$prof"
  [[ -f "$profiledir/SOUL.md" ]] || fail "Profile $prof is missing SOUL.md"
  [[ -f "$profiledir/memories/USER.md" ]] || warn "Profile $prof has no memories/USER.md"
  [[ -f "$profiledir/skills.txt" ]] || fail "Profile $prof is missing skills.txt"
  local stage="$RENDER_DIR/bootstrap-profile/$prof"
  rm -rf "$stage"
  mkdir -p "$stage"
  if [[ -d "$shared" ]]; then
    log "Composing bootstrap profile $prof"
    find "$shared" -mindepth 1 -maxdepth 1 ! -name skills -exec cp -a {} "$stage"/ \;
  fi
  mkdir -p "$stage/skills"
  local skill
  while IFS= read -r skill || [[ -n "$skill" ]]; do
    skill="${skill%%#*}"
    skill="${skill//[[:space:]]/}"
    [[ -n "$skill" ]] || continue
    [[ "$skill" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Invalid skill name '$skill' in profile $prof"
    [[ -d "$shared_skills/$skill" ]] || fail "Profile $prof selects missing shared skill: $skill"
    [[ ! -e "$stage/skills/$skill" ]] || fail "Profile $prof selects duplicate skill: $skill"
    cp -a "$shared_skills/$skill" "$stage/skills/$skill"
  done < "$profiledir/skills.txt"
  cp -a "$profiledir"/. "$stage"/
  rm -f "$stage/defaults.conf" "$stage/skills.txt" "$stage/requirements.txt"
  if [[ ! "$HERMES_ANSIBLE_SETUP" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
    rm -rf "$stage/workspace/ansible"
  fi
  export HERMES_BOOTSTRAP_DIR="$stage"
}

archive_enabled() {
  bootstrap_enabled || addon_requirements_enabled || is_truthy "$HERMES_ANSIBLE_SETUP"
}

copy_bootstrap_path() {
  local src="$1" dest="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$dest")"
  if [[ -d "$src" ]]; then
    mkdir -p "$dest"
    cp -a "$src"/. "$dest"/
  else
    cp -a "$src" "$dest"
  fi
}

create_bootstrap_archive() {
  rm -f "$BOOTSTRAP_ARCHIVE"
  rm -rf "$BOOTSTRAP_STAGE"
  if ! archive_enabled; then
    return 0
  fi

  mkdir -p "$BOOTSTRAP_STAGE/opt-data" "$BOOTSTRAP_STAGE/workspace" "$BOOTSTRAP_STAGE/addons"

  if bootstrap_enabled; then
    log "Preparing bootstrap archive from $HERMES_BOOTSTRAP_DIR"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/SOUL.md" "$BOOTSTRAP_STAGE/opt-data/SOUL.md"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/config.yaml" "$BOOTSTRAP_STAGE/opt-data/config.yaml"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/.env" "$BOOTSTRAP_STAGE/opt-data/.env"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/memories" "$BOOTSTRAP_STAGE/opt-data/memories"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/skills" "$BOOTSTRAP_STAGE/opt-data/skills"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/plugins" "$BOOTSTRAP_STAGE/opt-data/plugins"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/cron" "$BOOTSTRAP_STAGE/opt-data/cron"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/workspace" "$BOOTSTRAP_STAGE/workspace"

    if [[ "$HERMES_BOOTSTRAP_INCLUDE_AUTH" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
      copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/auth.json" "$BOOTSTRAP_STAGE/opt-data/auth.json"
    elif [[ -e "$HERMES_BOOTSTRAP_DIR/auth.json" ]]; then
      warn "bootstrap/auth.json exists but HERMES_BOOTSTRAP_INCLUDE_AUTH is false; auth.json was not included."
    fi
  fi

  if addon_requirements_enabled; then
    log "Including addon Python requirements from $HERMES_ADDON_REQUIREMENTS"
    copy_bootstrap_path "$HERMES_ADDON_REQUIREMENTS" "$BOOTSTRAP_STAGE/addons/requirements.txt"
  fi

  if is_truthy "$HERMES_ANSIBLE_SETUP" || [[ "${HERMES_PROFILE_REQUIREMENTS_SELECTED:-false}" == true ]]; then
    python3 "$ROOT_DIR/scripts/prepare_requirements.py" \
      "$BOOTSTRAP_STAGE/addons/requirements.txt" \
      "$HERMES_ANSIBLE_SETUP" \
      "$HERMES_ANSIBLE_VERSION" \
      "${HERMES_PROFILE_REQUIREMENTS_SELECTED:-false}"
  fi

  if ! find "$BOOTSTRAP_STAGE" -type f -print -quit | grep -q .; then
    warn "bootstrap/addon archive requested but no supported files were found."
    rm -rf "$BOOTSTRAP_STAGE"
    return 0
  fi

  tar -C "$BOOTSTRAP_STAGE" -czf "$BOOTSTRAP_ARCHIVE" .
  chmod 600 "$BOOTSTRAP_ARCHIVE"
}

render_manifest() {
  mkdir -p "$RENDER_DIR"
  python3 "$ROOT_DIR/scripts/render_template.py" \
    "$ROOT_DIR/manifests/hermes.yaml.tpl" \
    "$MANIFEST_OUT"
}

create_namespace_and_secrets() {
  log "Creating namespace and secrets"
  kubectl create namespace "$HERMES_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  if [[ -f "$BOOTSTRAP_ARCHIVE" ]]; then
    kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-bootstrap-archive       --from-file=bootstrap.tar.gz="$BOOTSTRAP_ARCHIVE"       --dry-run=client -o yaml | kubectl apply -f -
  else
    kubectl -n "$HERMES_NAMESPACE" delete secret hermes-bootstrap-archive --ignore-not-found=true >/dev/null
  fi

  if is_truthy "$HERMES_DASHBOARD_ENABLED" || is_truthy "$HERMES_WEBUI_ENABLED"; then
    local dash_tmpdir
    dash_tmpdir="$(mktemp -d)"
    chmod 700 "$dash_tmpdir"
    printf '%s' "$DASHBOARD_AUTH_USER" > "$dash_tmpdir/username"
    printf '%s' "$DASHBOARD_AUTH_PASSWORD" > "$dash_tmpdir/password"
    kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-dashboard-auth \
      --from-file=username="$dash_tmpdir/username" \
      --from-file=password="$dash_tmpdir/password" \
      --dry-run=client -o yaml | kubectl apply -f -
    rm -rf "$dash_tmpdir"
  else
    kubectl -n "$HERMES_NAMESPACE" delete secret hermes-dashboard-auth --ignore-not-found=true >/dev/null
  fi

  local secret_tmpdir
  secret_tmpdir="$(mktemp -d)"
  chmod 700 "$secret_tmpdir"
  printf '%s' "$API_SERVER_KEY" > "$secret_tmpdir/api-key"
  printf '%s' "$BROWSER_TOKEN" > "$secret_tmpdir/token"
  printf '%s' "$BROWSER_CDP_URL" > "$secret_tmpdir/BROWSER_CDP_URL"

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-api-server \
    --from-file=api-key="$secret_tmpdir/api-key" \
    --dry-run=client -o yaml | kubectl apply -f -

  if is_truthy "$HERMES_BROWSER_ENABLED"; then
    kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-token \
      --from-file=token="$secret_tmpdir/token" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    kubectl -n "$HERMES_NAMESPACE" delete secret hermes-browser-token --ignore-not-found=true >/dev/null
  fi

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-cdp \
    --from-file=BROWSER_CDP_URL="$secret_tmpdir/BROWSER_CDP_URL" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -rf "$secret_tmpdir"
}

apply_and_wait() {
  log "Recreating init job if it already exists"
  kubectl -n "$HERMES_NAMESPACE" delete job hermes-init-config --ignore-not-found=true --wait=true >/dev/null

  log "Applying manifest"
  kubectl apply -f "$MANIFEST_OUT"

  is_truthy "$HERMES_DASHBOARD_ENABLED" || kubectl -n "$HERMES_NAMESPACE" delete deploy,svc,ingress hermes-dashboard --ignore-not-found=true >/dev/null
  is_truthy "$HERMES_DASHBOARD_ENABLED" || kubectl -n "$HERMES_NAMESPACE" delete ingress hermes-dashboard-login --ignore-not-found=true >/dev/null
  is_truthy "$HERMES_DASHBOARD_ENABLED" || kubectl -n "$HERMES_NAMESPACE" delete middleware hermes-dashboard-login-rewrite --ignore-not-found=true >/dev/null 2>&1 || true
  is_truthy "$HERMES_WEBUI_ENABLED" || kubectl -n "$HERMES_NAMESPACE" delete deploy,svc,ingress hermes-webui --ignore-not-found=true >/dev/null
  if ! is_truthy "$HERMES_BROWSER_ENABLED"; then
    kubectl -n "$HERMES_NAMESPACE" delete deploy,svc hermes-browser --ignore-not-found=true >/dev/null
    kubectl -n "$HERMES_NAMESPACE" delete networkpolicy hermes-browser-restrict --ignore-not-found=true >/dev/null
  fi

  log "Waiting for init config job"
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=complete job/hermes-init-config --timeout=300s

  log "Restarting deployments to pick up refreshed secrets"
  local deployments=()
  mapfile -t deployments < <(enabled_deployments)
  kubectl -n "$HERMES_NAMESPACE" rollout restart "${deployments[@]/#/deploy/}" >/dev/null

  log "Waiting for rollouts"
  for d in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
}

print_summary() {
  cat <<EOF

Hermes Kubernetes setup applied.

Namespace:        $HERMES_NAMESPACE
WebUI host:       ${WEBUI_HOST:-disabled}
Dashboard host:   ${DASHBOARD_HOST:-disabled}
Browser enabled:  $HERMES_BROWSER_ENABLED
Rendered file:    $MANIFEST_OUT

Runtime credentials were applied through Kubernetes Secrets.
No credential values were stored locally or printed.
Extract the Dashboard/WebUI password when needed with:

  kubectl -n "$HERMES_NAMESPACE" get secret hermes-dashboard-auth -o jsonpath='{.data.password}' | base64 -d; printf '\n'

Extract the API server key with:

  kubectl -n "$HERMES_NAMESPACE" get secret hermes-api-server -o jsonpath='{.data.api-key}' | base64 -d; printf '\n'

Extract the Browserless token with:

  kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-token -o jsonpath='{.data.token}' | base64 -d; printf '\n'

Rotate later with:

  ./maintain.sh rotate-passwords

Next step for OpenAI Codex OAuth:

  kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
  hermes model

Run diagnostics:

  ./doctor.sh
EOF
}

main() {
  load_env
  prepare_paths
  prepare_defaults
  resolve_runtime_credentials
  validate
  create_bootstrap_archive
  render_manifest
  create_namespace_and_secrets
  apply_and_wait
  print_summary
}

if [[ "${HERMES_INSTALL_LIB_ONLY:-false}" != "true" ]]; then
  main "$@"
fi
