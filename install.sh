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
  export ENABLE_TRAEFIK_MIDDLEWARE="${ENABLE_TRAEFIK_MIDDLEWARE:-true}"
  export TRAEFIK_ENTRYPOINT="${TRAEFIK_ENTRYPOINT:-websecure}"
  export TLS_ENABLED="${TLS_ENABLED:-true}"
  export TLS_SECRET_NAME="${TLS_SECRET_NAME:-}"
  export HERMES_AGENT_IMAGE="${HERMES_AGENT_IMAGE:-nousresearch/hermes-agent:latest}"
  export HERMES_WEBUI_IMAGE="${HERMES_WEBUI_IMAGE:-ghcr.io/nesquena/hermes-webui:latest}"
  export HERMES_BROWSER_IMAGE="${HERMES_BROWSER_IMAGE:-ghcr.io/browserless/chromium:latest}"
  export HERMES_HOME_STORAGE_SIZE="${HERMES_HOME_STORAGE_SIZE:-10Gi}"
  export HERMES_WORKSPACE_STORAGE_SIZE="${HERMES_WORKSPACE_STORAGE_SIZE:-20Gi}"
  export STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-}"
  export MODEL_PROVIDER="${MODEL_PROVIDER:-codex}"
  export MODEL_NAME="${MODEL_NAME:-o4-mini}"
  export BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
  export BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-$(rand_hex 18)}"
  export DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER:-admin}"
  export DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD:-$(rand_hex 18)}"
  export API_SERVER_KEY="${API_SERVER_KEY:-$(rand_hex 32)}"
  export BROWSER_TOKEN="${BROWSER_TOKEN:-$(rand_hex 32)}"
  export BROWSER_CONCURRENT="${BROWSER_CONCURRENT:-2}"
  export BROWSER_QUEUED="${BROWSER_QUEUED:-10}"
  export BROWSER_TIMEOUT_MS="${BROWSER_TIMEOUT_MS:-300000}"
  export BROWSER_CDP_URL="ws://hermes-browser:3000/chromium?token=${BROWSER_TOKEN}"
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

  local basic_hash
  basic_hash="$(openssl passwd -apr1 "$BASIC_AUTH_PASSWORD")"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-basic-auth-users \
    --from-literal=users="${BASIC_AUTH_USER}:${basic_hash}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-dashboard-auth \
    --from-literal=username="$DASHBOARD_AUTH_USER" \
    --from-literal=password="$DASHBOARD_AUTH_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-api-server \
    --from-literal=api-key="$API_SERVER_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-token \
    --from-literal=token="$BROWSER_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-cdp \
    --from-literal=BROWSER_CDP_URL="$BROWSER_CDP_URL" \
    --dry-run=client -o yaml | kubectl apply -f -
}

apply_and_wait() {
  log "Applying manifest"
  kubectl apply -f "$MANIFEST_OUT"

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
If passwords were auto-generated, capture them from your shell environment or rotate them with:

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
  create_namespace_and_secrets
  apply_and_wait
  print_summary
}

main "$@"
