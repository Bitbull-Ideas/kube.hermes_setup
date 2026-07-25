#!/usr/bin/env bash
# Purpose: Operate and inspect an existing Hermes Kubernetes/K3s deployment.
# Scope: Provide status, restart/upgrade, backup/restore, credential display and rotation,
#        while keeping operations constrained to the configured namespace.
# Requirements: Bash, kubectl, age, Python 3, base64, OpenSSL, and sha256sum where applicable.
# Usage: ./maintain.sh {status|show-passwords|restart|upgrade|backup|extract|restore|rotate-passwords|rotate-browser-token}
# Exit status: 0 means the requested operation completed; non-zero identifies a failure.
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
parse_env_file() {
  local key encoded value
  while IFS=$'\t' read -r key encoded; do
    [[ -n "$key" ]] || continue
    value="$(printf '%s' "$encoded" | base64 -d)" || { printf 'ERROR: unable to decode environment setting %s\n' "$key" >&2; exit 1; }
    printf -v "$key" '%s' "$value"
    export "$key"
  done < <(python3 - "$ENV_FILE" <<'PY'
import base64, shlex, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            try:
                fields = shlex.split(stripped, comments=True, posix=True)
            except ValueError as exc:
                raise SystemExit(f"invalid environment syntax at line {number}: {exc}")
            if len(fields) != 1 or "=" not in fields[0]:
                raise SystemExit(f"invalid environment assignment at line {number}")
            key, value = fields[0].split("=", 1)
            if not key or not (key[0].isalpha() or key[0] == "_") or not all(c.isalnum() or c == "_" for c in key):
                raise SystemExit(f"invalid environment variable name at line {number}")
            if key in {"BASH_ENV", "ENV", "CDPATH", "PATH", "SHELLOPTS", "BASHOPTS", "GLOBIGNORE", "PYTHONPATH", "PYTHONINSPECT"} or key.startswith("LD_"):
                raise SystemExit(f"unsafe environment variable at line {number}")
            print(f"{key}\t{base64.b64encode(value.encode()).decode()}")
except OSError as exc:
    raise SystemExit(f"unable to read environment file: {exc}")
PY
  )
}
[[ -f "$ENV_FILE" ]] && {
  command -v python3 >/dev/null 2>&1 || { printf 'ERROR: Missing required command: python3\n' >&2; exit 1; }
  command -v base64 >/dev/null 2>&1 || { printf 'ERROR: Missing required command: base64\n' >&2; exit 1; }
  parse_env_file
}
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
require_cmd() {
  local command_name="$1" install_hint
  command -v "$command_name" >/dev/null 2>&1 && return 0
  case "$command_name" in
    age) install_hint='Install it on Fedora/RHEL with: dnf install age' ;;
    kubectl) install_hint='Install kubectl or k3s, then ensure kubectl is in PATH' ;;
    python3) install_hint='Install it with: dnf install python3' ;;
    sha256sum) install_hint='Install it with: dnf install coreutils' ;;
    base64) install_hint='Install it with: dnf install coreutils' ;;
    *) install_hint="Install the package providing '$command_name' and ensure it is in PATH" ;;
  esac
  fail "Missing required command: $command_name. $install_hint."
}
rand_hex() { openssl rand -hex "${1:-32}"; }
generate_password() { openssl rand -base64 "${1:-36}" | tr -d '\n'; }
validate_backup_archive() {
  local archive="$1"
  python3 - "$archive" <<'PY'
import posixpath
import sys
import tarfile

archive = sys.argv[1]
allowed = ("opt/data", "workspace", "metadata")
try:
    with tarfile.open(archive, "r:gz") as stream:
        for member in stream.getmembers():
            name = member.name.replace("\\", "/")
            if name.startswith("/") or any(part in {".", ".."} for part in name.split("/")):
                raise SystemExit(f"unsafe archive path: {member.name}")
            normalized = posixpath.normpath(name)
            if not any(normalized == root or normalized.startswith(root + "/") for root in allowed):
                raise SystemExit(f"archive path outside allowed roots: {member.name}")
            if member.issym() or member.islnk():
                raise SystemExit(f"links are not allowed in backup archives: {member.name}")
            if not (member.isdir() or member.isfile()):
                raise SystemExit(f"unsupported archive entry: {member.name}")
except (OSError, tarfile.TarError) as exc:
    raise SystemExit(f"invalid backup archive: {exc}")
PY
}

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
  ./maintain.sh backup <backup.age> [--password-prompt|--password-file PATH|--password-stdin]
  ./maintain.sh restore <backup.age> [--password-prompt|--password-file PATH|--password-stdin]
  ./maintain.sh extract <backup.age> --output-dir PATH [--component data|config|bootstrap|full]
      [--password-prompt|--password-file PATH|--password-stdin] [--dry-run]
  ./maintain.sh show-passwords
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

get_secret_value() {
  local secret="$1" key="$2" encoded
  encoded="$(kubectl -n "$HERMES_NAMESPACE" get secret "$secret" -o "jsonpath={.data['$key']}")"
  [[ -n "$encoded" ]] || fail "Missing credential: secret=$secret key=$key"
  printf '%s' "$encoded" | base64 -d || fail "Unable to decode credential: secret=$secret key=$key"
}
show_secret_value() {
  local label="$1" secret="$2" key="$3" value
  value="$(get_secret_value "$secret" "$key")"
  printf '%s: %s\n' "$label" "$value"
}

prepare_backup_password() {
  local mode=prompt password='' password_source=''
  BACKUP_PASSWORD_TMP="$(mktemp -d -t hermes-backup-password.XXXXXX)"
  chmod 700 "$BACKUP_PASSWORD_TMP"
  while (($#)); do
    case "$1" in
      --password-prompt) mode=prompt; shift ;;
      --password-stdin) mode=stdin; shift ;;
      --password-file)
        [[ $# -ge 2 ]] || fail '--password-file requires a path'
        mode=file; password_source="$2"; shift 2 ;;
      --password-file=*) mode=file; password_source="${1#*=}"; shift ;;
      *) fail "unknown backup password option: $1" ;;
    esac
  done
  case "$mode" in
    prompt)
      [[ -t 0 ]] || fail 'interactive password prompt requires a TTY; use --password-stdin or --password-file for automation'
      read -r -s -p 'Backup passphrase: ' password
      printf '\n' >&2
      ;;
    stdin) IFS= read -r password || true ;;
    file)
      [[ -f "$password_source" ]] || fail "password file not found: $password_source"
      local file_mode
      file_mode="$(stat -c '%a' "$password_source")"
      [[ "$file_mode" =~ ^6[04]0$ ]] || fail "password file must be owner-readable only (mode 600 or 640)"
      IFS= read -r password < "$password_source" || true
      ;;
  esac
  [[ -n "$password" ]] || fail 'backup encryption password must not be empty'
  printf '%s\n' "$password" > "$BACKUP_PASSWORD_TMP/password"
  chmod 600 "$BACKUP_PASSWORD_TMP/password"
  unset password
}

show_passwords() {
  command -v base64 >/dev/null 2>&1 || fail "Missing required command: base64"
  printf '%s\n' "Credentials for namespace $HERMES_NAMESPACE:"
  show_secret_value "Dashboard/WebUI password" hermes-dashboard-auth password
  show_secret_value "API server key" hermes-api-server api-key
  show_secret_value "Browserless token" hermes-browser-token token
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

create_storage_helper_pod() {
  local name="$1" container="$2"
  cat <<JSON | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${HERMES_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: ${container}
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
}

backup() {
  local out='' arg plain checksum tmpdir
  local -a password_args=()
  while (($#)); do
    case "$1" in
      --password-prompt|--password-stdin|--password-file|--password-file=*) password_args+=("$1"); [[ "$1" == '--password-file' ]] && { [[ $# -ge 2 ]] || fail '--password-file requires a path'; password_args+=("$2"); shift; }; shift ;;
      -*) fail "unknown backup option: $1" ;;
      *) [[ -z "$out" ]] || fail 'backup path specified more than once'; out="$1"; shift ;;
    esac
  done
  [[ -n "$out" ]] || fail 'backup path required'
  require_cmd age
  require_cmd sha256sum
  mkdir -p "$(dirname "$out")"
  checksum="${out}.sha256"
  tmpdir="$(mktemp -d -t hermes-backup.XXXXXX)"
  plain="$tmpdir/hermes-backup.tgz"
  prepare_backup_password "${password_args[@]}"
  backup_cleanup() {
    kubectl -n "$HERMES_NAMESPACE" delete pod hermes-backup --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
    rm -rf -- "$tmpdir" "$BACKUP_PASSWORD_TMP"
  }
  backup_on_exit() {
    local status=$?
    backup_cleanup
    trap - EXIT
    exit "$status"
  }
  trap backup_on_exit EXIT
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-backup --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  create_storage_helper_pod hermes-backup backup
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready pod/hermes-backup --timeout=120s >/dev/null
  kubectl -n "$HERMES_NAMESPACE" exec hermes-backup -- sh -c 'umask 077; tar czf /tmp/hermes-backup.tgz -C / opt/data workspace; chmod 600 /tmp/hermes-backup.tgz'
  kubectl -n "$HERMES_NAMESPACE" cp hermes-backup:/tmp/hermes-backup.tgz "$tmpdir/cluster.tgz" -c backup >/dev/null
  chmod 600 "$tmpdir/cluster.tgz"
  mkdir -p "$tmpdir/stage/metadata"
  tar -xzf "$tmpdir/cluster.tgz" -C "$tmpdir/stage"
  if [[ -f "$ROOT_DIR/current_config/hermes.env" ]]; then
    cp -a "$ROOT_DIR/current_config/hermes.env" "$tmpdir/stage/metadata/hermes.env"
  elif [[ -f "$ROOT_DIR/hermes.env" ]]; then
    cp -a "$ROOT_DIR/hermes.env" "$tmpdir/stage/metadata/hermes.env"
  fi
  [[ -f "$ROOT_DIR/configuration_answers" ]] && cp -a "$ROOT_DIR/configuration_answers" "$tmpdir/stage/metadata/configuration_answers"
  [[ -d "$ROOT_DIR/current_config/bootstrap" ]] && cp -a "$ROOT_DIR/current_config/bootstrap" "$tmpdir/stage/metadata/bootstrap"
  printf 'namespace=%s\ncreated_at=%s\n' "$HERMES_NAMESPACE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmpdir/stage/metadata/backup-info.txt"
  chmod -R go-rwx "$tmpdir/stage/metadata"
  tar -czf "$plain" -C "$tmpdir/stage" opt/data workspace metadata
  chmod 600 "$plain"
  # The wrapper supplies the passphrase through a private PTY, never argv or logs.
  python3 "$ROOT_DIR/scripts/age_passphrase.py" "$BACKUP_PASSWORD_TMP/password" -- \
    age --passphrase --armor --output "$out" "$plain"
  chmod 600 "$out"
  sha256sum "$out" > "$checksum"
  chmod 600 "$checksum"
  sha256sum -c "$checksum"
  trap - EXIT
  backup_cleanup
  ls -lh "$out" "$checksum"
}

extract_backup() {
  local in='' output_dir='' component='' dry_run=false tmpdir='' plain='' arg
  local -a password_args=()
  while (($#)); do
    case "$1" in
      --output-dir)
        [[ $# -ge 2 ]] || fail '--output-dir requires a path'
        output_dir="$2"; shift 2 ;;
      --output-dir=*) output_dir="${1#*=}"; shift ;;
      --component)
        [[ $# -ge 2 ]] || fail '--component requires data, config, or bootstrap'
        component="$2"; shift 2 ;;
      --component=*) component="${1#*=}"; shift ;;
      --full) component=full; shift ;;
      --dry-run) dry_run=true; shift ;;
      --password-prompt|--password-stdin|--password-file|--password-file=*)
        password_args+=("$1")
        if [[ "$1" == '--password-file' ]]; then
          [[ $# -ge 2 ]] || fail '--password-file requires a path'
          password_args+=("$2"); shift
        fi
        shift ;;
      *)
        [[ -z "$in" ]] || fail 'backup path specified more than once'
        in="$1"; shift ;;
    esac
  done
  [[ -f "$in" ]] || fail 'backup file required'
  [[ -n "$output_dir" ]] || fail '--output-dir is required for extract'
  [[ "$component" == data || "$component" == config || "$component" == bootstrap || "$component" == full ]] || fail '--component or --full is required for extract'
  require_cmd age
  require_cmd python3
  tmpdir="$(mktemp -d -t hermes-extract.XXXXXX)"
  plain="$tmpdir/hermes-backup.tgz"
  extract_cleanup() { rm -rf -- "$tmpdir" "$BACKUP_PASSWORD_TMP"; }
  extract_on_exit() { local status=$?; extract_cleanup; trap - EXIT; exit "$status"; }
  trap extract_on_exit EXIT
  prepare_backup_password "${password_args[@]}"
  python3 "$ROOT_DIR/scripts/age_passphrase.py" "$BACKUP_PASSWORD_TMP/password" -- \
    age --decrypt --output "$plain" "$in" >/dev/null
  validate_backup_archive "$plain" || fail 'backup archive validation failed'
  if [[ -e "$output_dir" && ! -d "$output_dir" ]]; then
    fail "extract output path is not a directory: $output_dir"
  fi
  if [[ "$dry_run" != true ]] && [[ -d "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "extract output directory is not empty: $output_dir"
  fi
  if [[ "$dry_run" == true ]]; then
    printf 'Backup: valid\nMode: extract\nComponent: %s\nOutput directory: %s\nNo files written: dry-run\n' "$component" "$output_dir"
    trap - EXIT
    extract_cleanup
    return 0
  fi
  mkdir -p "$output_dir"
  chmod 700 "$output_dir"
  python3 - "$plain" "$output_dir" "$component" <<'PY'
import os
import shutil
import sys
import tarfile

archive, destination, component = sys.argv[1:]
selected = {
    "data": ("opt/data", "workspace"),
    "config": ("metadata/hermes.env", "metadata/configuration_answers", "metadata/backup-info.txt"),
    "bootstrap": ("metadata/bootstrap",),
    "full": ("opt/data", "workspace", "metadata"),
}[component]

def choose(name):
    return any(name == root or name.startswith(root + "/") for root in selected)

def mapped(name):
    if name.startswith("metadata/"):
        return name[len("metadata/"):]
    return name

with tarfile.open(archive, "r:gz") as stream:
    for member in stream.getmembers():
        if not choose(member.name):
            continue
        target = os.path.join(destination, mapped(member.name))
        if member.isdir():
            os.makedirs(target, mode=0o700, exist_ok=True)
            continue
        if not member.isfile():
            raise SystemExit(f"unsupported selected archive entry: {member.name}")
        os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
        source = stream.extractfile(member)
        if source is None:
            raise SystemExit(f"unable to read selected archive entry: {member.name}")
        with open(target, "wb") as output:
            shutil.copyfileobj(source, output)
        os.chmod(target, member.mode & 0o700 or 0o600)
PY
  printf 'Extracted component %s to %s\n' "$component" "$output_dir"
  trap - EXIT
  extract_cleanup
}
restore() {
  local in='' plain='' tmpdir='' arg
  local -a password_args=()
  while (($#)); do
    case "$1" in
      --password-prompt|--password-stdin|--password-file|--password-file=*) password_args+=("$1"); [[ "$1" == '--password-file' ]] && { [[ $# -ge 2 ]] || fail '--password-file requires a path'; password_args+=("$2"); shift; }; shift ;;
      -*) fail "unknown restore option: $1" ;;
      *) [[ -z "$in" ]] || fail 'restore path specified more than once'; in="$1"; shift ;;
    esac
  done
  [[ -f "$in" ]] || fail "backup file required"
  require_cmd age
  require_cmd python3
  tmpdir="$(mktemp -d -t hermes-restore.XXXXXX)"
  plain="$tmpdir/hermes-backup.tgz"
  prepare_backup_password "${password_args[@]}"
  restore_local_cleanup() { rm -rf -- "$tmpdir" "$BACKUP_PASSWORD_TMP"; }
  restore_local_on_exit() { local status=$?; restore_local_cleanup; trap - EXIT; exit "$status"; }
  trap restore_local_on_exit EXIT
  python3 "$ROOT_DIR/scripts/age_passphrase.py" "$BACKUP_PASSWORD_TMP/password" -- \
    age --decrypt --output "$plain" "$in"
  validate_backup_archive "$plain" || fail "decrypted backup archive validation failed"
  mkdir -p "$tmpdir/payload"
  tar -xzf "$plain" -C "$tmpdir/payload" opt/data workspace
  tar -czf "$tmpdir/restore-payload.tgz" -C "$tmpdir/payload" opt/data workspace
  plain="$tmpdir/restore-payload.tgz"
  [[ "$HERMES_RUNTIME_UID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_UID must be numeric"
  [[ "$HERMES_RUNTIME_GID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_GID must be numeric"
  local deployments=() d replicas
  mapfile -t deployments < <(enabled_write_deployments)
  declare -A original_replicas=()
  for d in "${deployments[@]}"; do
    replicas="$(kubectl -n "$HERMES_NAMESPACE" get deploy "$d" -o jsonpath='{.spec.replicas}')"
    original_replicas["$d"]="${replicas:-1}"
  done
  restore_cleanup() {
    kubectl -n "$HERMES_NAMESPACE" delete pod hermes-restore --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
    for d in "${deployments[@]}"; do
      kubectl -n "$HERMES_NAMESPACE" scale "deploy/$d" --replicas="${original_replicas[$d]}" >/dev/null 2>&1 || true
    done
    restore_local_cleanup
  }
  restore_on_exit() {
    local status=$?
    restore_cleanup
    trap - EXIT
    exit "$status"
  }
  trap restore_on_exit EXIT
  log "Scaling down write-heavy deployments"
  kubectl -n "$HERMES_NAMESPACE" scale "${deployments[@]/#/deploy/}" --replicas=0
  kubectl -n "$HERMES_NAMESPACE" rollout status deploy/hermes-agent --timeout=120s >/dev/null 2>&1 || true
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-restore --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  create_storage_helper_pod hermes-restore restore
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready pod/hermes-restore --timeout=120s >/dev/null
  kubectl -n "$HERMES_NAMESPACE" cp "$plain" hermes-restore:/tmp/hermes-backup.tgz -c restore >/dev/null
  kubectl -n "$HERMES_NAMESPACE" exec hermes-restore -- sh -c "find /opt/data /workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} +; tar xzf /tmp/hermes-backup.tgz -C /; chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace"
  log "Scaling deployments up"
  for d in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" scale "deploy/$d" --replicas="${original_replicas[$d]}"
  done
  for d in "${deployments[@]}"; do
    if [[ "${original_replicas[$d]}" -gt 0 ]]; then
      kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
    fi
  done
  trap - EXIT
  restore_cleanup
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
  trap 'rm -rf -- "$tmpdir"' ERR
  printf '%s' "$user" > "$tmpdir/username"
  printf '%s' "$pass" > "$tmpdir/password"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-dashboard-auth \
    --from-file=username="$tmpdir/username" \
    --from-file=password="$tmpdir/password" \
    --dry-run=client -o yaml | kubectl apply -f -
  trap - ERR
  rm -rf -- "$tmpdir"
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
  --generate  Generate a new random password and store it only in the Kubernetes Secret.
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
  local dashboard_pass=""

  case "$input_mode" in
    generate)
      dashboard_pass="$(generate_password 36)"
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
The generated password is stored only in Kubernetes Secret hermes-dashboard-auth.
Show the current credentials with:
  ./maintain.sh show-passwords
For lab passwords use --lab or HERMES_PASSWORD_POLICY=lab explicitly.
EOF
}
rotate_browser_token() {
  is_truthy "$HERMES_BROWSER_ENABLED" || fail "Browser component is disabled"
  local token="${BROWSER_TOKEN:-$(rand_hex 32)}" deployments=() d tmpdir
  mapfile -t deployments < <(enabled_deployments)
  local cdp="ws://hermes-browser:3000/chromium?token=${token}"
  tmpdir="$(mktemp -d -t hermes-browser-token.XXXXXX)"
  chmod 700 "$tmpdir"
  trap 'rm -rf -- "$tmpdir"' ERR
  printf '%s' "$token" > "$tmpdir/token"
  printf '%s' "$cdp" > "$tmpdir/BROWSER_CDP_URL"
  chmod 600 "$tmpdir/token" "$tmpdir/BROWSER_CDP_URL"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-token \
    --from-file=token="$tmpdir/token" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-cdp \
    --from-file=BROWSER_CDP_URL="$tmpdir/BROWSER_CDP_URL" \
    --dry-run=client -o yaml | kubectl apply -f -
  trap - ERR
  rm -rf -- "$tmpdir"
  kubectl -n "$HERMES_NAMESPACE" rollout restart "${deployments[@]/#/deploy/}"
  for d in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
  echo "Rotated Browserless token. CDP endpoint: ws://hermes-browser:3000/chromium?token=<redacted>"
}

if [[ "${HERMES_MAINTAIN_LIB_ONLY:-false}" != true ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    status) status "$@" ;;
    show-passwords) show_passwords "$@" ;;
    restart) restart "$@" ;;
    upgrade) upgrade "$@" ;;
    backup) backup "$@" ;;
    extract) extract_backup "$@" ;;
    restore) restore "$@" ;;
    rotate-passwords) rotate_passwords "$@" ;;
    rotate-browser-token) rotate_browser_token "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage; fail "unknown command: $cmd" ;;
  esac
fi
