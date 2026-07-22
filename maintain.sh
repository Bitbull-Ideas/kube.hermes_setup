#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Rotation input passed explicitly in the process environment must survive
# sourcing an env file that intentionally keeps generated values blank.
PROCESS_DASHBOARD_AUTH_USER_SET="${DASHBOARD_AUTH_USER+x}"
PROCESS_DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER-}"
PROCESS_DASHBOARD_AUTH_PASSWORD_SET="${DASHBOARD_AUTH_PASSWORD+x}"
PROCESS_DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD-}"
PROCESS_BROWSER_TOKEN_SET="${BROWSER_TOKEN+x}"
PROCESS_BROWSER_TOKEN="${BROWSER_TOKEN-}"
DEFAULT_ENV_FILE="$ROOT_DIR/hermes.env"
if [[ ! -f "$DEFAULT_ENV_FILE" && -f "$ROOT_DIR/current_config/hermes.env" ]]; then
  DEFAULT_ENV_FILE="$ROOT_DIR/current_config/hermes.env"
fi
ENV_FILE="${ENV_FILE:-$DEFAULT_ENV_FILE}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
[[ -z "$PROCESS_DASHBOARD_AUTH_USER_SET" ]] || DASHBOARD_AUTH_USER="$PROCESS_DASHBOARD_AUTH_USER"
[[ -z "$PROCESS_DASHBOARD_AUTH_PASSWORD_SET" ]] || DASHBOARD_AUTH_PASSWORD="$PROCESS_DASHBOARD_AUTH_PASSWORD"
[[ -z "$PROCESS_BROWSER_TOKEN_SET" ]] || BROWSER_TOKEN="$PROCESS_BROWSER_TOKEN"
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
HERMES_DASHBOARD_ENABLED="${HERMES_DASHBOARD_ENABLED:-true}"
HERMES_WEBUI_ENABLED="${HERMES_WEBUI_ENABLED:-true}"
HERMES_BROWSER_ENABLED="${HERMES_BROWSER_ENABLED:-true}"
HERMES_RENDER_DIR="${HERMES_RENDER_DIR:-$ROOT_DIR/.rendered}"
HERMES_RUNTIME_UID="${HERMES_RUNTIME_UID:-10000}"
HERMES_RUNTIME_GID="${HERMES_RUNTIME_GID:-10000}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
rand_hex() { openssl rand -hex "${1:-32}"; }
credential_output_file() { mkdir -p "$HERMES_RENDER_DIR"; chmod 700 "$HERMES_RENDER_DIR"; printf "%s/rotated-credentials-%s.txt" "$HERMES_RENDER_DIR" "$(date -u +%Y%m%dT%H%M%SZ)"; }
is_truthy() { [[ "${1:-}" =~ ^(1|true|TRUE|yes|YES|y|Y|on|ON)$ ]]; }
enabled_deployments() {
  printf '%s\n' hermes-agent
  is_truthy "$HERMES_DASHBOARD_ENABLED" && printf '%s\n' hermes-dashboard
  is_truthy "$HERMES_WEBUI_ENABLED" && printf '%s\n' hermes-webui
  is_truthy "$HERMES_BROWSER_ENABLED" && printf '%s\n' hermes-browser
}
enabled_write_deployments() {
  printf '%s\n' hermes-agent
  is_truthy "$HERMES_DASHBOARD_ENABLED" && printf '%s\n' hermes-dashboard
  is_truthy "$HERMES_WEBUI_ENABLED" && printf '%s\n' hermes-webui
}

usage() {
  cat <<'EOF'
Usage:
  ./maintain.sh status
  ./maintain.sh restart
  ./maintain.sh upgrade
  ./maintain.sh backup <backup.tgz>
  ./maintain.sh restore <backup.tgz>
  ./maintain.sh rotate-passwords [--lab] [--prompt|--generate|--from-env]
  ./maintain.sh rotate-browser-token

Environment:
  ENV_FILE=./hermes.env
  HERMES_NAMESPACE=hermes
  HERMES_PASSWORD_POLICY=production|lab
  DASHBOARD_AUTH_USER/DASHBOARD_AUTH_PASSWORD for Dashboard/WebUI auth
EOF
}

status() {
  kubectl -n "$HERMES_NAMESPACE" get pods,svc,ingress,networkpolicy -o wide
}

restart() {
  local deployments=() d
  mapfile -t deployments < <(enabled_deployments)
  kubectl -n "$HERMES_NAMESPACE" rollout restart "${deployments[@]/#/deploy/}"
  for d in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
}

upgrade() {
  log "Pulling fresh images by restarting deployments. Pin image tags in hermes.env for controlled production upgrades."
  restart
}

backup() {
  local out="${1:-}"
  [[ -n "$out" ]] || fail "backup path required"
  mkdir -p "$(dirname "$out")"
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-backup --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  cat <<JSON | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: hermes-backup
  namespace: ${HERMES_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: backup
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: home
      mountPath: /opt/data
    - name: workspace
      mountPath: /workspace
  volumes:
  - name: home
    persistentVolumeClaim:
      claimName: hermes-home
  - name: workspace
    persistentVolumeClaim:
      claimName: hermes-workspace
JSON
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready pod/hermes-backup --timeout=120s >/dev/null
  kubectl -n "$HERMES_NAMESPACE" exec hermes-backup -- sh -c 'tar czf /tmp/hermes-backup.tgz -C / opt/data workspace'
  kubectl -n "$HERMES_NAMESPACE" cp hermes-backup:/tmp/hermes-backup.tgz "$out" -c backup >/dev/null
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-backup --ignore-not-found=true --wait=true >/dev/null
  sha256sum "$out"
  ls -lh "$out"
}

restore() {
  local in="${1:-}"
  [[ -f "$in" ]] || fail "backup file required"
  [[ "$HERMES_RUNTIME_UID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_UID must be numeric"
  [[ "$HERMES_RUNTIME_GID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_GID must be numeric"
  local deployments=() d
  mapfile -t deployments < <(enabled_write_deployments)
  log "Scaling down write-heavy deployments"
  kubectl -n "$HERMES_NAMESPACE" scale "${deployments[@]/#/deploy/}" --replicas=0
  kubectl -n "$HERMES_NAMESPACE" rollout status deploy/hermes-agent --timeout=120s >/dev/null 2>&1 || true
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-restore --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  cat <<JSON | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: hermes-restore
  namespace: ${HERMES_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: restore
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: home
      mountPath: /opt/data
    - name: workspace
      mountPath: /workspace
  volumes:
  - name: home
    persistentVolumeClaim:
      claimName: hermes-home
  - name: workspace
    persistentVolumeClaim:
      claimName: hermes-workspace
JSON
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready pod/hermes-restore --timeout=120s >/dev/null
  kubectl -n "$HERMES_NAMESPACE" cp "$in" hermes-restore:/tmp/hermes-backup.tgz -c restore >/dev/null
  kubectl -n "$HERMES_NAMESPACE" exec hermes-restore -- sh -c "find /opt/data /workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} +; tar xzf /tmp/hermes-backup.tgz -C /; chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace"
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-restore --ignore-not-found=true --wait=true >/dev/null
  log "Scaling deployments up"
  kubectl -n "$HERMES_NAMESPACE" scale "${deployments[@]/#/deploy/}" --replicas=1
  for d in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
}

prompt_secret() {
  local label="$1"
  [[ -t 0 ]] || fail "$label requires an interactive TTY. Use --from-env with exported variables or --generate for non-interactive rotation."
  local first second
  while true; do
    read -r -s -p "$label: " first; printf '
' >&2
    read -r -s -p "Confirm $label: " second; printf '
' >&2
    [[ "$first" == "$second" ]] || { printf 'Passwords did not match. Try again.
' >&2; continue; }
    [[ -n "$first" ]] || { printf 'Password must not be empty.
' >&2; continue; }
    printf '%s' "$first"
    return 0
  done
}

secret_from_env() {
  local var_name="$1" value=""
  value="$(printenv "$var_name" 2>/dev/null || true)"
  [[ -n "$value" ]] || fail "$var_name is required with --from-env. Export it before running maintain.sh."
  printf '%s' "$value"
}

password_is_strong() {
  local pass="$1"
  [[ ${#pass} -ge 14 ]] || return 1
  [[ "$pass" =~ [a-z] ]] || return 1
  [[ "$pass" =~ [A-Z] ]] || return 1
  [[ "$pass" =~ [0-9] ]] || return 1
  [[ "$pass" =~ [^a-zA-Z0-9] ]] || return 1
}

allow_weak_password() {
  local mode="${HERMES_PASSWORD_POLICY:-production}"
  [[ "$mode" == "lab" ]] && return 0
  is_truthy "${HERMES_ALLOW_WEAK_PASSWORD:-}" && return 0
  return 1
}

confirm_weak_password_if_interactive() {
  local label="$1" pass="$2" mode="${HERMES_PASSWORD_POLICY:-production}"
  if password_is_strong "$pass"; then
    return 0
  fi
  if allow_weak_password; then
    warn "Weak $label accepted because HERMES_PASSWORD_POLICY=$mode or HERMES_ALLOW_WEAK_PASSWORD is set. Use this only for labs."
    return 0
  fi
  if [[ -t 0 ]]; then
    warn "$label does not meet the production recommendation: >=14 chars with lower/upper/digit/symbol."
    read -r -p "Accept weak $label for a lab/test install? Type 'lab' to continue: " answer
    if [[ "$answer" == "lab" ]]; then
      export HERMES_PASSWORD_POLICY=lab
      warn "Proceeding in lab password mode for this run."
      return 0
    fi
  fi
  fail "Weak $label rejected. Use a stronger value, or set HERMES_PASSWORD_POLICY=lab / HERMES_ALLOW_WEAK_PASSWORD=true for lab systems."
}

apply_dashboard_auth_secret() {
  local user="$1" pass="$2" tmpdir
  tmpdir="$(mktemp -d)"
  chmod 700 "$tmpdir"
  printf '%s' "$user" > "$tmpdir/username"
  printf '%s' "$pass" > "$tmpdir/password"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-dashboard-auth \
    --from-file=username="$tmpdir/username" \
    --from-file=password="$tmpdir/password" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -rf "$tmpdir"
}

rotate_passwords() {
  local input_mode="auto"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lab) export HERMES_PASSWORD_POLICY=lab ;;
      --generate) input_mode="generate" ;;
      --prompt) input_mode="prompt" ;;
      --from-env|--env) input_mode="env" ;;
      --help|-h)
        cat <<'EOF'
Usage:
  ./maintain.sh rotate-passwords [--lab] [--prompt|--generate|--from-env]

Passwords controlled:
  Dashboard + WebUI: DASHBOARD_AUTH_USER / DASHBOARD_AUTH_PASSWORD

Input modes:
  --prompt    Always ask with hidden interactive prompts. This is the default when stdin is a TTY.
  --generate  Generate a new random password and write it to HERMES_RENDER_DIR/rotated-credentials-*.txt.
  --from-env  Read DASHBOARD_AUTH_PASSWORD from environment variables. Use this for CI/non-interactive automation.

Important:
  Values present in hermes.env are NOT silently reused in interactive mode. This prevents a "rotation" that applies the old password again.
  Production policy rejects weak passwords by default. For labs, use --lab or:
    HERMES_PASSWORD_POLICY=lab ./maintain.sh rotate-passwords
EOF
        return 0 ;;
      *) fail "unknown rotate-passwords option: $1" ;;
    esac
    shift
  done

  if [[ "$input_mode" == "auto" ]]; then
    if [[ -t 0 ]]; then
      input_mode="prompt"
    else
      input_mode="env"
    fi
  fi

  local dashboard_user="${DASHBOARD_AUTH_USER:-admin}"
  local dashboard_pass="" generated_file=""
  if [[ "$input_mode" == "generate" ]]; then
    generated_file="$(credential_output_file)"
    umask 077
    : > "$generated_file"
  fi

  case "$input_mode" in
    generate)
      dashboard_pass="$(rand_hex 18)"
      printf 'DASHBOARD_AUTH_USER=%s
DASHBOARD_AUTH_PASSWORD=%s
' "$dashboard_user" "$dashboard_pass" >> "$generated_file"
      ;;
    env)
      dashboard_pass="$(secret_from_env DASHBOARD_AUTH_PASSWORD)"
      ;;
    prompt)
      dashboard_pass="$(prompt_secret 'Dashboard/WebUI password')"
      ;;
    *) fail "unsupported password input mode: $input_mode" ;;
  esac

  confirm_weak_password_if_interactive "Dashboard/WebUI password" "$dashboard_pass"
  local auth_deployments=() d
  is_truthy "$HERMES_DASHBOARD_ENABLED" && auth_deployments+=(deploy/hermes-dashboard)
  is_truthy "$HERMES_WEBUI_ENABLED" && auth_deployments+=(deploy/hermes-webui)
  ((${#auth_deployments[@]} > 0)) || fail "Dashboard and WebUI are both disabled; there is no application password to rotate"
  apply_dashboard_auth_secret "$dashboard_user" "$dashboard_pass"
  kubectl -n "$HERMES_NAMESPACE" rollout restart "${auth_deployments[@]}"
  for d in "${auth_deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "$d" --timeout=300s
  done

  cat <<EOF
Rotated Dashboard/WebUI password secret.
Input mode:          $input_mode
Dashboard/WebUI:     updated for dashboard user '$dashboard_user'; WebUI password uses the same secret

Plaintext passwords were not printed. Store env-provided/generated values in your password manager.
For lab passwords use --lab or HERMES_PASSWORD_POLICY=lab explicitly.
EOF
  if [[ "$input_mode" == "generate" ]]; then
    chmod 600 "$generated_file"
    warn "--generate was used. Generated plaintext values were written to $generated_file (gitignored, mode 600). Move them to your password manager and delete the file."
  fi
}
rotate_browser_token() {
  is_truthy "$HERMES_BROWSER_ENABLED" || fail "Browser component is disabled"
  local token="${BROWSER_TOKEN:-$(rand_hex 32)}" deployments=() d
  mapfile -t deployments < <(enabled_deployments)
  local cdp="ws://hermes-browser:3000/chromium?token=${token}"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-token --from-literal=token="$token" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-cdp --from-literal=BROWSER_CDP_URL="$cdp" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$HERMES_NAMESPACE" rollout restart "${deployments[@]/#/deploy/}"
  for d in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
  echo "Rotated Browserless token. CDP endpoint: ws://hermes-browser:3000/chromium?token=<redacted>"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  status) status "$@" ;;
  restart) restart "$@" ;;
  upgrade) upgrade "$@" ;;
  backup) backup "$@" ;;
  restore) restore "$@" ;;
  rotate-passwords) rotate_passwords "$@" ;;
  rotate-browser-token) rotate_browser_token "$@" ;;
  -h|--help|help|"") usage ;;
  *) usage; fail "unknown command: $cmd" ;;
esac
