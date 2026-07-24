#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-credentials-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"

cat > "$TMP_DIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_KUBECTL_STATE:?}"
mkdir -p "$state"
printf '%s\n' "$*" >> "$state/calls"
if [[ "${1:-}" == -n ]]; then
  shift 2
fi

if [[ "${FAKE_KUBECTL_ERROR:-}" == namespace && "${1:-}" == get && "${2:-}" == namespace ]]; then
  printf '%s\n' 'Error from server: namespace lookup failed' >&2
  exit 1
fi
if [[ "${FAKE_KUBECTL_ERROR:-}" == secret && "${1:-}" == get && "${2:-}" == secret ]]; then
  printf '%s\n' 'Error from server: secret lookup failed' >&2
  exit 1
fi

if [[ "${1:-}" == get && "${2:-}" == namespace ]]; then
  if [[ -f "$state/namespace" ]]; then
    printf '%s' "${3:-}"
  fi
  exit 0
fi

if [[ "${1:-}" == get && "${2:-}" == secret ]]; then
  secret="${3:-}"
  shift 3
  if [[ ! -d "$state/secrets/$secret" ]]; then
    exit 0
  fi
  output=''
  while (($#)); do
    if [[ "$1" == -o ]]; then
      output="${2:-}"
      shift 2
    else
      shift
    fi
  done
  case "$output" in
    'jsonpath={.metadata.name}') printf '%s' "$secret" ;;
    "jsonpath={.data['username']}") key=username ;;
    "jsonpath={.data['password']}") key=password ;;
    "jsonpath={.data['api-key']}") key=api-key ;;
    "jsonpath={.data['token']}") key=token ;;
    *) printf 'unsupported jsonpath: %s\n' "$output" >&2; exit 2 ;;
  esac
  [[ -z "${key:-}" ]] || [[ ! -f "$state/secrets/$secret/$key" ]] || cat "$state/secrets/$secret/$key"
  exit 0
fi

printf 'unexpected kubectl call: %s\n' "$*" >&2
exit 2
KUBECTL
chmod +x "$TMP_DIR/bin/kubectl"

encode() { printf '%s' "$1" | openssl base64 -A; }
put_secret() {
  local secret="$1" key="$2" value="$3"
  mkdir -p "$TMP_DIR/state/secrets/$secret"
  encode "$value" > "$TMP_DIR/state/secrets/$secret/$key"
}
reset_state() {
  rm -rf "$TMP_DIR/state"
  mkdir -p "$TMP_DIR/state"
  : > "$TMP_DIR/state/calls"
}

run_resolver() {
  local label="$1" scenario="${2:-default}"
  local render_dir="$TMP_DIR/render-$label"
  rm -rf "$render_dir"
  mkdir -p "$render_dir"
  ROOT_DIR="$ROOT_DIR" TMP_DIR="$TMP_DIR" TEST_SCENARIO="$scenario" TEST_LABEL="$label" \
  FAKE_KUBECTL_STATE="$TMP_DIR/state" HERMES_RENDER_DIR="$render_dir" \
  PATH="$TMP_DIR/bin:$PATH" bash -s >"$TMP_DIR/$label.stdout" 2>"$TMP_DIR/$label.stderr" <<'RUNNER'
set -euo pipefail
export HERMES_INSTALL_LIB_ONLY=true
export HERMES_NAMESPACE=hermes HERMES_BOOTSTRAP_PROFILE= HERMES_BOOTSTRAP_MODE=disabled
export HERMES_DASHBOARD_ENABLED=true HERMES_WEBUI_ENABLED=true HERMES_BROWSER_ENABLED=true
unset DASHBOARD_AUTH_USER DASHBOARD_AUTH_PASSWORD API_SERVER_KEY BROWSER_TOKEN BROWSER_CDP_URL
case "$TEST_SCENARIO" in
  explicit)
    export DASHBOARD_AUTH_USER=explicit-user DASHBOARD_AUTH_PASSWORD=explicit-password
    export API_SERVER_KEY=explicit-api-key-long BROWSER_TOKEN=explicit-browser-token
    ;;
  disabled)
    export HERMES_DASHBOARD_ENABLED=false HERMES_WEBUI_ENABLED=false HERMES_BROWSER_ENABLED=false
    ;;
  *) ;;
esac
# shellcheck disable=SC1090
source "$ROOT_DIR/install.sh"
prepare_paths
prepare_defaults
resolve_runtime_credentials
printf 'dashboard=%s api=%s browser=%s\n' "$CREDENTIAL_SOURCE_DASHBOARD" "$CREDENTIAL_SOURCE_API" "$CREDENTIAL_SOURCE_BROWSER" > "$TMP_DIR/$TEST_LABEL.sources"
printf 'dashboard_password_sha=%s\n' "$(printf '%s' "$DASHBOARD_AUTH_PASSWORD" | sha256sum | cut -d' ' -f1)" > "$TMP_DIR/$TEST_LABEL.result"
printf 'dashboard_user_sha=%s\n' "$(printf '%s' "$DASHBOARD_AUTH_USER" | sha256sum | cut -d' ' -f1)" >> "$TMP_DIR/$TEST_LABEL.result"
printf 'api_sha=%s\n' "$(printf '%s' "$API_SERVER_KEY" | sha256sum | cut -d' ' -f1)" >> "$TMP_DIR/$TEST_LABEL.result"
printf 'browser_sha=%s\n' "$(printf '%s' "$BROWSER_TOKEN" | sha256sum | cut -d' ' -f1)" >> "$TMP_DIR/$TEST_LABEL.result"
printf 'cdp_sha=%s\n' "$(printf '%s' "$BROWSER_CDP_URL" | sha256sum | cut -d' ' -f1)" >> "$TMP_DIR/$TEST_LABEL.result"
RUNNER
}

assert_failed() {
  local label="$1" expected="$2" error_mode="$3"
  if FAKE_KUBECTL_ERROR="$error_mode" run_resolver "$label"; then
    printf 'expected failure: %s\n' "$label" >&2
    exit 1
  fi
  grep -Fq "$expected" "$TMP_DIR/$label.stderr"
  ! grep -Eq 'create|apply' "$TMP_DIR/state/calls"
}

# Explicit process-environment credentials survive loading a blank env file.
printf '%s\n' 'DASHBOARD_AUTH_PASSWORD=' 'API_SERVER_KEY=' 'BROWSER_TOKEN=' > "$TMP_DIR/blank.env"
PATH="$TMP_DIR/bin:$PATH" ENV_FILE="$TMP_DIR/blank.env" HERMES_INSTALL_LIB_ONLY=true \
HERMES_NAMESPACE=precedence-test HERMES_DASHBOARD_ENABLED=false HERMES_WEBUI_ENABLED=false \
HERMES_BROWSER_ENABLED=false API_SERVER_KEY=explicit-api-key-long \
bash -c 'source "$1"; load_env; prepare_paths; prepare_defaults; printf "%s" "$API_SERVER_KEY" | sha256sum | cut -d" " -f1' _ "$ROOT_DIR/install.sh" \
  > "$TMP_DIR/process-precedence.sha"
expected_process_sha="$(printf '%s' explicit-api-key-long | sha256sum | cut -d' ' -f1)"
grep -qx "$expected_process_sha" "$TMP_DIR/process-precedence.sha"

# First installation: missing namespace means all enabled credentials are generated.
reset_state
run_resolver fresh
grep -qx 'dashboard=generated api=generated browser=generated' "$TMP_DIR/fresh.sources"
! compgen -G "$TMP_DIR/render-fresh/generated-credentials.txt" >/dev/null
! compgen -G "$TMP_DIR/render-fresh/.generated-credentials.*" >/dev/null
touch "$TMP_DIR/render-fresh/generated-credentials.txt" "$TMP_DIR/render-fresh/rotated-credentials-old.txt"
HERMES_INSTALL_LIB_ONLY=true HERMES_RENDER_DIR="$TMP_DIR/render-fresh" bash -c 'source "$1"; prepare_paths; remove_local_credential_captures' _ "$ROOT_DIR/install.sh"
! compgen -G "$TMP_DIR/render-fresh/generated-credentials.txt" >/dev/null
! compgen -G "$TMP_DIR/render-fresh/rotated-credentials-*.txt" >/dev/null

# Existing Secrets: blank configuration reuses values without exposing them.
reset_state
touch "$TMP_DIR/state/namespace"
put_secret hermes-dashboard-auth username existing-user
put_secret hermes-dashboard-auth password existing-dashboard-password
put_secret hermes-api-server api-key existing-api-key-long-enough
put_secret hermes-browser-token token existing-browser-token
run_resolver reuse
grep -qx 'dashboard=reused api=reused browser=reused' "$TMP_DIR/reuse.sources"
grep -q 'dashboard_password_sha=' "$TMP_DIR/reuse.result"
grep -q 'dashboard_user_sha=' "$TMP_DIR/reuse.result"
grep -q 'api_sha=' "$TMP_DIR/reuse.result"
grep -q 'browser_sha=' "$TMP_DIR/reuse.result"
expected_user_sha="$(printf '%s' existing-user | sha256sum | cut -d' ' -f1)"
grep -qx "dashboard_user_sha=$expected_user_sha" "$TMP_DIR/reuse.result"
! compgen -G "$TMP_DIR/render-reuse/generated-credentials.txt" >/dev/null
expected_cdp_sha="$(printf '%s' 'ws://hermes-browser:3000/chromium?token=existing-browser-token' | sha256sum | cut -d' ' -f1)"
grep -qx "cdp_sha=$expected_cdp_sha" "$TMP_DIR/reuse.result"
cp "$TMP_DIR/reuse.result" "$TMP_DIR/reuse-first.result"
run_resolver reuse-second
grep -qx 'dashboard=reused api=reused browser=reused' "$TMP_DIR/reuse-second.sources"
cmp -s "$TMP_DIR/reuse-first.result" "$TMP_DIR/reuse-second.result"

# One missing Secret generates only that source; existing values remain reused.
rm -rf "$TMP_DIR/state/secrets/hermes-browser-token"
run_resolver one-missing
grep -qx 'dashboard=reused api=reused browser=generated' "$TMP_DIR/one-missing.sources"

# Explicit values win and do not query Kubernetes.
reset_state
run_resolver explicit explicit
grep -qx 'dashboard=explicit api=explicit browser=explicit' "$TMP_DIR/explicit.sources"
! grep -q 'get ' "$TMP_DIR/state/calls"

# Disabled optional components remain empty and are not looked up.
reset_state
run_resolver disabled disabled
grep -qx 'dashboard= api=generated browser=' "$TMP_DIR/disabled.sources"
! grep -q 'hermes-dashboard-auth\|hermes-browser-token' "$TMP_DIR/state/calls"
empty_sha="$(printf '' | sha256sum | cut -d' ' -f1)"
grep -qx "dashboard_password_sha=$empty_sha" "$TMP_DIR/disabled.result"
grep -qx "browser_sha=$empty_sha" "$TMP_DIR/disabled.result"

# Fail closed for Kubernetes errors and malformed/weak existing Secrets.
reset_state
assert_failed namespace-error 'Unable to inspect namespace' namespace
reset_state
touch "$TMP_DIR/state/namespace"
assert_failed secret-error 'Unable to safely resolve Dashboard/WebUI credentials' secret
reset_state
touch "$TMP_DIR/state/namespace"
mkdir -p "$TMP_DIR/state/secrets/hermes-dashboard-auth"
printf '%s' 'not-base64!' > "$TMP_DIR/state/secrets/hermes-dashboard-auth/password"
assert_failed malformed 'malformed or empty' none
: > "$TMP_DIR/state/secrets/hermes-dashboard-auth/password"
assert_failed empty 'missing required key password' none
reset_state
touch "$TMP_DIR/state/namespace"
put_secret hermes-dashboard-auth username existing-user
put_secret hermes-dashboard-auth password existing-dashboard-password
put_secret hermes-api-server api-key short
put_secret hermes-browser-token token existing-browser-token
assert_failed weak-api 'API_SERVER_KEY must be at least 16 characters' none

# No fixture Secret value may appear in test output.
if grep -R -F -e existing-dashboard-password -e existing-api-key-long-enough -e existing-browser-token \
    "$TMP_DIR"/*.stdout "$TMP_DIR"/*.stderr 2>/dev/null; then
  printf 'credential value leaked to test output\n' >&2
  exit 1
fi

printf 'credential preservation tests passed\n'
