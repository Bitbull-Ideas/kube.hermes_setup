#!/usr/bin/env bash
# Purpose: Verify doctor auth-mode drift/conflict diagnostics without a cluster.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-auth-doctor-test.XXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *'get deployment hermes-dashboard -o json'* ]]; then
  cat <<'JSON'
{"spec":{"template":{"spec":{"containers":[{"env":[
{"name":"HERMES_DASHBOARD_OIDC_ISSUER","value":"https://sso.example.com"},
{"name":"HERMES_DASHBOARD_OIDC_CLIENT_ID","value":"hermes-dashboard"},
{"name":"HERMES_DASHBOARD_OIDC_SCOPES","value":"openid profile email groups"},
{"name":"HERMES_DASHBOARD_PUBLIC_URL","value":"https://hermes-admin.example.com"}
]}]}}}}
JSON
  exit 0
fi
if [[ "$args" == *'get deployment hermes-webui -o json'* ]]; then
  cat <<JSON
{"spec":{"template":{"spec":{"containers":[{"env":[
{"name":"HERMES_WEBUI_OIDC_ISSUER","value":"https://sso.example.com"},
{"name":"HERMES_WEBUI_OIDC_CLIENT_ID","value":"hermes-webui"},
{"name":"HERMES_WEBUI_OIDC_SCOPES","value":"openid profile email groups"},
{"name":"HERMES_WEBUI_OIDC_REDIRECT_URI","value":"https://hermes.example.com/api/auth/oidc/callback"},
{"name":"HERMES_WEBUI_OIDC_ALLOW_CLAIM","value":"groups"},
{"name":"HERMES_WEBUI_OIDC_ALLOW_VALUES","value":"hermes-qa-users"},
{"name":"HERMES_WEBUI_SESSION_TTL","value":"${FAKE_WEBUI_SESSION_TTL:-43200}"}
]}]}}}}
JSON
  exit 0
fi
if [[ "$args" == *'get secret hermes-dashboard-auth --ignore-not-found -o name'* ]]; then
  [[ "${FAKE_RESOURCE_ERROR:-false}" == true ]] && exit 1
  [[ "${FAKE_LOCAL_SECRET:-false}" == true ]] && printf '%s\n' 'secret/hermes-dashboard-auth'
  exit 0
fi
if [[ "$args" == *'get ingress hermes-dashboard-login --ignore-not-found -o name'* ]]; then
  [[ "${FAKE_RESOURCE_ERROR:-false}" == true ]] && exit 1
  [[ "${FAKE_LOGIN_INGRESS:-false}" == true ]] && printf '%s\n' 'ingress.networking.k8s.io/hermes-dashboard-login'
  exit 0
fi
if [[ "$args" == *'get middleware hermes-dashboard-login-rewrite --ignore-not-found -o name'* ]]; then
  [[ "${FAKE_RESOURCE_ERROR:-false}" == true ]] && exit 1
  [[ "${FAKE_LOGIN_MIDDLEWARE:-false}" == true ]] && printf '%s\n' 'middleware.traefik.io/hermes-dashboard-login-rewrite'
  exit 0
fi
exit 1
EOF
chmod 0755 "$TMP_DIR/bin/kubectl"

common_env=(
  HERMES_DOCTOR_LIB_ONLY=true
  HERMES_AUTH_MODE=external-oidc
  HERMES_NAMESPACE=hermes
  HERMES_DASHBOARD_ENABLED=true
  HERMES_WEBUI_ENABLED=true
  HERMES_BROWSER_ENABLED=false
  HERMES_OIDC_ISSUER=https://sso.example.com
  HERMES_DASHBOARD_OIDC_ISSUER=https://sso.example.com
  HERMES_WEBUI_OIDC_ISSUER=https://sso.example.com
  HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-dashboard
  HERMES_DASHBOARD_OIDC_SCOPES="openid profile email groups"
  HERMES_WEBUI_OIDC_CLIENT_ID=hermes-webui
  HERMES_WEBUI_OIDC_SCOPES="openid profile email groups"
  HERMES_DASHBOARD_PUBLIC_URL=https://hermes-admin.example.com
  HERMES_WEBUI_OIDC_REDIRECT_URI=https://hermes.example.com/api/auth/oidc/callback
  HERMES_WEBUI_OIDC_ALLOW_CLAIM=groups
  HERMES_WEBUI_OIDC_ALLOW_VALUES=hermes-qa-users
  HERMES_AUTH_SESSION_MAX_TTL_SECONDS=43200
  HERMES_AUTH_SESSION_IDLE_TTL_SECONDS=7200
)

if ! env PATH="$TMP_DIR/bin:$PATH" "${common_env[@]}" \
  bash -c 'source "$1"; check_auth_mode; [[ "$fail_count" == 0 ]]' _ "$ROOT_DIR/doctor.sh" \
  > "$TMP_DIR/clean.out"; then
  cat "$TMP_DIR/clean.out" >&2
  exit 1
fi
grep -Fq 'external-oidc local application password Secret absent' "$TMP_DIR/clean.out"
grep -Fq 'hermes-webui HERMES_WEBUI_OIDC_REDIRECT_URI matches configured auth mode' "$TMP_DIR/clean.out"
grep -Fq 'hermes-webui HERMES_WEBUI_SESSION_TTL matches configured auth mode' "$TMP_DIR/clean.out"

env PATH="$TMP_DIR/bin:$PATH" FAKE_WEBUI_SESSION_TTL=43199 "${common_env[@]}" \
  bash -c 'source "$1"; check_auth_mode; [[ "$fail_count" == 1 ]]' _ "$ROOT_DIR/doctor.sh" \
  > "$TMP_DIR/session-ttl-drift.out"
grep -Fq 'hermes-webui HERMES_WEBUI_SESSION_TTL missing or drifted' "$TMP_DIR/session-ttl-drift.out"

env PATH="$TMP_DIR/bin:$PATH" "${common_env[@]}" \
  bash -c 'unset HERMES_DASHBOARD_OIDC_SCOPES HERMES_WEBUI_OIDC_SCOPES; source "$1"; check_auth_mode; [[ "$fail_count" == 0 ]]' _ "$ROOT_DIR/doctor.sh" \
  > "$TMP_DIR/default-scopes.out"
grep -Fq 'hermes-dashboard HERMES_DASHBOARD_OIDC_SCOPES matches configured auth mode' "$TMP_DIR/default-scopes.out"
grep -Fq 'hermes-webui HERMES_WEBUI_OIDC_SCOPES matches configured auth mode' "$TMP_DIR/default-scopes.out"

env PATH="$TMP_DIR/bin:$PATH" FAKE_LOCAL_SECRET=true "${common_env[@]}" \
  bash -c 'source "$1"; check_auth_mode; [[ "$fail_count" == 1 ]]' _ "$ROOT_DIR/doctor.sh" \
  > "$TMP_DIR/conflict.out"
grep -Fq 'external-oidc local application password Secret still exists' "$TMP_DIR/conflict.out"

env PATH="$TMP_DIR/bin:$PATH" FAKE_LOGIN_INGRESS=true FAKE_LOGIN_MIDDLEWARE=true "${common_env[@]}" \
  bash -c 'source "$1"; check_auth_mode; [[ "$fail_count" == 2 ]]' _ "$ROOT_DIR/doctor.sh" \
  > "$TMP_DIR/routes.out"
grep -Fq 'external-oidc Dashboard password-login Ingress still exists' "$TMP_DIR/routes.out"
grep -Fq 'external-oidc Dashboard password-login Middleware still exists' "$TMP_DIR/routes.out"

env PATH="$TMP_DIR/bin:$PATH" FAKE_RESOURCE_ERROR=true "${common_env[@]}" \
  bash -c 'source "$1"; check_auth_mode; [[ "$fail_count" == 3 ]]' _ "$ROOT_DIR/doctor.sh" \
  > "$TMP_DIR/unreadable.out"
grep -Fq 'unable to verify external-oidc local application password Secret absence' "$TMP_DIR/unreadable.out"
grep -Fq 'unable to verify external-oidc Dashboard password-login Ingress absence' "$TMP_DIR/unreadable.out"
grep -Fq 'unable to verify external-oidc Dashboard password-login Middleware absence' "$TMP_DIR/unreadable.out"

env PATH="$TMP_DIR/bin:$PATH" "${common_env[@]}" HERMES_WEBUI_OIDC_ALLOW_VALUES= \
  bash -c 'source "$1"; check_auth_mode; [[ "$fail_count" == 2 ]]' _ "$ROOT_DIR/doctor.sh" \
  > "$TMP_DIR/blank.out"
grep -Fq 'configured HERMES_WEBUI_OIDC_ALLOW_VALUES is empty' "$TMP_DIR/blank.out"
grep -Fq 'hermes-webui HERMES_WEBUI_OIDC_ALLOW_VALUES missing or drifted' "$TMP_DIR/blank.out"

printf 'doctor auth-mode checks passed\n'
