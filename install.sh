#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/hermes.env}"
RENDER_DIR="$ROOT_DIR/.rendered"
MANIFEST_OUT="$RENDER_DIR/hermes.yaml"
BOOTSTRAP_ARCHIVE="$RENDER_DIR/bootstrap.tar.gz"
BOOTSTRAP_STAGE="$RENDER_DIR/bootstrap-stage"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
rand_hex() { openssl rand -hex "${1:-32}"; }
write_generated_credentials() {
  mkdir -p "$RENDER_DIR"
  chmod 700 "$RENDER_DIR"
  local out="$RENDER_DIR/generated-credentials.txt"
  {
    printf "DASHBOARD_AUTH_USER=%s\nDASHBOARD_AUTH_PASSWORD=%s\n" "$DASHBOARD_AUTH_USER" "$DASHBOARD_AUTH_PASSWORD"
    printf "API_SERVER_KEY=%s\n" "$API_SERVER_KEY"
    printf "BROWSER_TOKEN=%s\n" "$BROWSER_TOKEN"
  } > "$out"
  chmod 600 "$out"
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    fail "Missing env file: $ENV_FILE. Copy examples/hermes.env.example to hermes.env first."
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

validate() {
  require_cmd kubectl
  require_cmd openssl
  [[ -n "${HERMES_NAMESPACE:-}" ]] || fail "HERMES_NAMESPACE is required"
  [[ -n "${WEBUI_HOST:-}" ]] || fail "WEBUI_HOST is required"
  [[ -n "${DASHBOARD_HOST:-}" ]] || fail "DASHBOARD_HOST is required"
  [[ "$WEBUI_HOST" != *example.com ]] || warn "WEBUI_HOST still uses example.com"
  [[ "$DASHBOARD_HOST" != *example.com ]] || warn "DASHBOARD_HOST still uses example.com"
}

prepare_defaults() {
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
  export DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER:-admin}"
  export DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD:-$(rand_hex 18)}"
  export API_SERVER_KEY="${API_SERVER_KEY:-$(rand_hex 32)}"
  if [[ ${#API_SERVER_KEY} -lt 16 ]]; then
    warn "API_SERVER_KEY is shorter than 16 characters; generating a strong key instead."
    export API_SERVER_KEY="$(rand_hex 32)"
  fi
  export BROWSER_TOKEN="${BROWSER_TOKEN:-$(rand_hex 32)}"
  export BROWSER_CONCURRENT="${BROWSER_CONCURRENT:-2}"
  export BROWSER_QUEUED="${BROWSER_QUEUED:-10}"
  export BROWSER_TIMEOUT_MS="${BROWSER_TIMEOUT_MS:-300000}"
  [[ "$BROWSER_CONCURRENT" =~ ^[0-9]+$ ]] || fail "BROWSER_CONCURRENT must be numeric"
  [[ "$BROWSER_QUEUED" =~ ^[0-9]+$ ]] || fail "BROWSER_QUEUED must be numeric"
  if (( BROWSER_CONCURRENT < 2 )); then
    warn "BROWSER_CONCURRENT=$BROWSER_CONCURRENT is below the repo default 2; WebUI screenshot/browser workflows can queue and time out during CDP handshakes."
  fi
  export BROWSER_CDP_URL="ws://hermes-browser:3000/chromium?token=${BROWSER_TOKEN}"
  case "$HERMES_BOOTSTRAP_MODE" in
    disabled|missing|overwrite) ;;
    *) fail "HERMES_BOOTSTRAP_MODE must be one of: disabled, missing, overwrite" ;;
  esac
  if [[ -n "$HERMES_BOOTSTRAP_DIR" && "$HERMES_BOOTSTRAP_MODE" != "disabled" ]]; then
    require_cmd tar
    [[ -d "$HERMES_BOOTSTRAP_DIR" ]] || fail "HERMES_BOOTSTRAP_DIR does not exist or is not a directory: $HERMES_BOOTSTRAP_DIR"
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

archive_enabled() {
  bootstrap_enabled || addon_requirements_enabled
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

  local secret_tmpdir
  secret_tmpdir="$(mktemp -d)"
  chmod 700 "$secret_tmpdir"
  printf '%s' "$API_SERVER_KEY" > "$secret_tmpdir/api-key"
  printf '%s' "$BROWSER_TOKEN" > "$secret_tmpdir/token"
  printf '%s' "$BROWSER_CDP_URL" > "$secret_tmpdir/BROWSER_CDP_URL"

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-api-server \
    --from-file=api-key="$secret_tmpdir/api-key" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-token \
    --from-file=token="$secret_tmpdir/token" \
    --dry-run=client -o yaml | kubectl apply -f -

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

  log "Waiting for init config job"
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=complete job/hermes-init-config --timeout=300s

  log "Restarting deployments to pick up refreshed secrets"
  kubectl -n "$HERMES_NAMESPACE" rollout restart \
    deploy/hermes-agent \
    deploy/hermes-dashboard \
    deploy/hermes-webui \
    deploy/hermes-browser >/dev/null

  log "Waiting for rollouts"
  for d in hermes-agent hermes-dashboard hermes-webui hermes-browser; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
}

print_summary() {
  cat <<EOF

Hermes Kubernetes setup applied.

Namespace:        $HERMES_NAMESPACE
WebUI host:       $WEBUI_HOST
Dashboard host:   $DASHBOARD_HOST
Browser CDP:      ws://hermes-browser:3000/chromium?token=<redacted>
Rendered file:    $MANIFEST_OUT

Generated/used credentials were applied as Kubernetes Secrets only.
A local credential capture file was written to .rendered/generated-credentials.txt with mode 600.
Move those values to your password manager and delete the file after use.

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
  validate
  prepare_defaults
  create_bootstrap_archive
  render_manifest
  write_generated_credentials
  create_namespace_and_secrets
  apply_and_wait
  print_summary
}

main "$@"
