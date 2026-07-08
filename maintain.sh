#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/hermes.env}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
rand_hex() { openssl rand -hex "${1:-32}"; }

usage() {
  cat <<'EOF'
Usage:
  ./maintain.sh status
  ./maintain.sh restart
  ./maintain.sh upgrade
  ./maintain.sh backup <backup.tgz>
  ./maintain.sh restore <backup.tgz>
  ./maintain.sh rotate-passwords
  ./maintain.sh rotate-browser-token

Environment:
  ENV_FILE=./hermes.env
  HERMES_NAMESPACE=hermes
EOF
}

status() {
  kubectl -n "$HERMES_NAMESPACE" get pods,svc,ingress,networkpolicy -o wide
}

restart() {
  kubectl -n "$HERMES_NAMESPACE" rollout restart deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui deploy/hermes-browser
  for d in hermes-agent hermes-dashboard hermes-webui hermes-browser; do
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
  log "Scaling down write-heavy deployments"
  kubectl -n "$HERMES_NAMESPACE" scale deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui --replicas=0
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
  kubectl -n "$HERMES_NAMESPACE" exec hermes-restore -- sh -c 'rm -rf /opt/data/* /workspace/*; tar xzf /tmp/hermes-backup.tgz -C /; chown -R 1000:1000 /opt/data /workspace || true'
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-restore --ignore-not-found=true --wait=true >/dev/null
  log "Scaling deployments up"
  kubectl -n "$HERMES_NAMESPACE" scale deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui --replicas=1
  for d in hermes-agent hermes-dashboard hermes-webui; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
}

rotate_passwords() {
  local basic_user="${BASIC_AUTH_USER:-admin}"
  local dashboard_user="${DASHBOARD_AUTH_USER:-admin}"
  local basic_pass="${BASIC_AUTH_PASSWORD:-$(rand_hex 18)}"
  local dashboard_pass="${DASHBOARD_AUTH_PASSWORD:-$(rand_hex 18)}"
  local basic_hash
  basic_hash="$(openssl passwd -apr1 "$basic_pass")"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-basic-auth-users \
    --from-literal=users="${basic_user}:${basic_hash}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-dashboard-auth \
    --from-literal=username="$dashboard_user" \
    --from-literal=password="$dashboard_pass" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$HERMES_NAMESPACE" rollout restart deploy/hermes-dashboard
  kubectl -n "$HERMES_NAMESPACE" rollout status deploy/hermes-dashboard --timeout=300s
  cat <<EOF
Rotated passwords.
Ingress user:   $basic_user
Ingress pass:   $basic_pass
Dashboard user: $dashboard_user
Dashboard pass: $dashboard_pass
Store these in your password manager. They are not written to git.
EOF
}

rotate_browser_token() {
  local token="${BROWSER_TOKEN:-$(rand_hex 32)}"
  local cdp="ws://hermes-browser:3000/chromium?token=${token}"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-token --from-literal=token="$token" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-cdp --from-literal=BROWSER_CDP_URL="$cdp" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$HERMES_NAMESPACE" rollout restart deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui deploy/hermes-browser
  for d in hermes-agent hermes-dashboard hermes-webui hermes-browser; do
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
