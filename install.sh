#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/hermes.env}"
RENDER_DIR="$ROOT_DIR/.rendered"
MANIFEST_OUT="$RENDER_DIR/hermes.yaml"

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
    printf "BASIC_AUTH_USER=%s\nBASIC_AUTH_PASSWORD=%s\n" "$BASIC_AUTH_USER" "$BASIC_AUTH_PASSWORD"
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
  export ENABLE_TRAEFIK_BASIC_AUTH="${ENABLE_TRAEFIK_BASIC_AUTH:-${ENABLE_TRAEFIK_MIDDLEWARE:-true}}"
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
  export STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-}"
  export MODEL_PROVIDER="${MODEL_PROVIDER:-codex}"
  export MODEL_NAME="${MODEL_NAME:-o4-mini}"
  export BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
  export BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-$(rand_hex 18)}"
  export DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER:-admin}"
  export DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD:-$(rand_hex 18)}"
  export API_SERVER_KEY="${API_SERVER_KEY:-$(rand_hex 32)}"
  export BROWSER_TOKEN="${BROWSER_TOKEN:-$(rand_hex 32)}"
  export BROWSER_CONCURRENT="${BROWSER_CONCURRENT:-6}"
  export BROWSER_QUEUED="${BROWSER_QUEUED:-20}"
  export BROWSER_TIMEOUT_MS="${BROWSER_TIMEOUT_MS:-300000}"
  [[ "$BROWSER_CONCURRENT" =~ ^[0-9]+$ ]] || fail "BROWSER_CONCURRENT must be numeric"
  [[ "$BROWSER_QUEUED" =~ ^[0-9]+$ ]] || fail "BROWSER_QUEUED must be numeric"
  if (( BROWSER_CONCURRENT < 6 )); then
    warn "BROWSER_CONCURRENT=$BROWSER_CONCURRENT is too low for WebUI browser-tool workflows; raising to 6 to avoid CDP handshake queue timeouts."
    export BROWSER_CONCURRENT=6
  fi
  if (( BROWSER_QUEUED < 20 )); then
    warn "BROWSER_QUEUED=$BROWSER_QUEUED is low for WebUI browser-tool workflows; raising to 20."
    export BROWSER_QUEUED=20
  fi
  export BROWSER_CDP_URL="ws://hermes-browser:3000/chromium?token=${BROWSER_TOKEN}"
  [[ "$HERMES_RUNTIME_UID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_UID must be numeric"
  [[ "$HERMES_RUNTIME_GID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_GID must be numeric"
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

  if [[ "$ENABLE_TRAEFIK_BASIC_AUTH" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
    local basic_hash tmpdir
    basic_hash="$(printf '%s\n' "$BASIC_AUTH_PASSWORD" | openssl passwd -apr1 -stdin)"
    tmpdir="$(mktemp -d)"
    chmod 700 "$tmpdir"
      printf '%s:%s\n' "$BASIC_AUTH_USER" "$basic_hash" > "$tmpdir/users"
    kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-basic-auth-users \
      --from-file=users="$tmpdir/users" \
      --dry-run=client -o yaml | kubectl apply -f -
    rm -rf "$tmpdir"
  else
    warn "Traefik Ingress BasicAuth is disabled. Dashboard internal auth remains enabled."
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
Ingress BasicAuth: ${ENABLE_TRAEFIK_BASIC_AUTH}
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
  render_manifest
  write_generated_credentials
  create_namespace_and_secrets
  apply_and_wait
  print_summary
}

main "$@"
