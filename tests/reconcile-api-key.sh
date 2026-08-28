#!/usr/bin/env bash
# Purpose: Verify Secret-authoritative API-key reconciliation without a cluster.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-api-key-reconcile.XXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

secret_key='secret-authoritative-api-key'
printf '%s\n' 'UNRELATED_SETTING=keep-me' 'API_SERVER_KEY=stale-one' 'API_SERVER_KEY=stale-two' > "$TMP_DIR/runtime.env"
chmod 640 "$TMP_DIR/runtime.env"

cat > "$TMP_DIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_KUBECTL_CALLS:?}"
if [[ "${1:-} ${2:-} ${3:-}" == 'apply -f -' ]]; then
  manifest="$(cat)"
  grep -Fq 'name: hermes-api-key-reconcile' <<<"$manifest"
  grep -Fq 'claimName: hermes-home' <<<"$manifest"
  grep -Fq 'automountServiceAccountToken: false' <<<"$manifest"
  exit 0
fi
[[ "${1:-}" == -n && "${2:-}" == hermes ]] || { printf 'unexpected namespace: %s\n' "$*" >&2; exit 2; }
shift 2
case "${1:-} ${2:-}" in
  'get secret')
    [[ "${3:-}" == hermes-api-server ]] || exit 2
    case "${5:-}" in
      json)
        count="$(cat "${FAKE_SNAPSHOT_COUNT:?}")"
        if [[ "${FAKE_ROTATE_ONCE:-false}" == true && "$count" == 0 ]]; then
          key='superseded-secret-api-key'
          revision=rv-secret-superseded
        else
          key="${FAKE_API_KEY:?}"
          revision=rv-secret-current
        fi
        printf '%s' "$((count + 1))" > "$FAKE_SNAPSHOT_COUNT"
        encoded="$(printf '%s' "$key" | base64 -w0)"
        printf '{"metadata":{"resourceVersion":"%s"},"data":{"api-key":"%s"}}\n' "$revision" "$encoded"
        ;;
      'jsonpath={.metadata.resourceVersion}') printf '%s' rv-secret-current ;;
      *) printf 'unexpected Secret lookup: %s\n' "$*" >&2; exit 2 ;;
    esac
    ;;
  'delete pod')
    exit 0
    ;;

  'wait --for=condition=Ready')
    [[ "${3:-}" == pod/hermes-api-key-reconcile ]] || exit 2
    ;;
  'exec -i')
    [[ "${3:-}" == hermes-api-key-reconcile && "${4:-}" == -- && "${5:-}" == sh && "${6:-}" == -c ]] || exit 2
    payload="$7"
    mode="${12:-write}"
    key="$(cat)"
    printf '%s' "$key" | sh -c "$payload" sh "${9:-10000}" "${10:-10000}" "${FAKE_ENV_FILE:?}" "$mode"
    ;;
  'get pods')
    app="${4#app=}"
    [[ "${7:-}" == json ]] || exit 2
    printf '{"items":[{"metadata":{"name":"%s-pod","annotations":{"kube-hermes-setup.example.com/api-key-revision":"rv-secret-current"}},"status":{"conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"ready":true}]}}]}\n' "$app"
    ;;
  'get deployment')
    case "${3:-}" in hermes-agent|hermes-dashboard|hermes-webui) ;; *) exit 2 ;; esac
    [[ "${3:-}" != "${FAKE_MISSING_DEPLOYMENT:-}" ]] || exit 1
    ;;
  'exec hermes-agent-pod'|'exec hermes-dashboard-pod'|'exec hermes-webui-pod')
    app="${2%-pod}"
    [[ "${3:-}" == -- && "${4:-}" == sh && "${5:-}" == -c ]] || exit 2
    payload="$6"
    [[ "$payload" == *'/health/detailed'* && "$payload" == *'Authorization'* && "$payload" == *'print("ok")'* ]] || exit 2
    [[ "$app" != "${FAKE_AUTH_FAIL_APP:-}" ]] || exit 1
    printf 'ok\n'
    ;;
  'patch deployment')
    app="$3"
    case "$app" in hermes-agent|hermes-dashboard|hermes-webui) ;; *) exit 2 ;; esac
    [[ "$*" == *'api-key-revision'* && "$*" == *'rv-secret-current'* ]] || exit 2
    [[ "$app" != "${FAKE_PATCH_FAIL_APP:-}" ]] || exit 1
    ;;
  'rollout status')
    exit 0
    ;;
  *)
    printf 'unexpected kubectl call: %s\n' "$*" >&2
    exit 2
    ;;
esac
KUBECTL
chmod 0755 "$TMP_DIR/bin/kubectl"

run_reconcile() {
  PATH="$TMP_DIR/bin:$PATH" \
  ENV_FILE=/dev/null \
  FAKE_API_KEY="$secret_key" \
  FAKE_ENV_FILE="$TMP_DIR/runtime.env" \
  FAKE_KUBECTL_CALLS="$TMP_DIR/kubectl.calls" \
  FAKE_SNAPSHOT_COUNT="$TMP_DIR/snapshot.count" \
  HERMES_NAMESPACE=hermes \
  HERMES_RUNTIME_UID="$(id -u)" \
  HERMES_RUNTIME_GID="$(id -g)" \
  HERMES_DASHBOARD_ENABLED=true \
  HERMES_WEBUI_ENABLED=true \
  "$@" "$ROOT_DIR/maintain.sh" reconcile-api-key --source secret
}

: > "$TMP_DIR/kubectl.calls"
printf '0' > "$TMP_DIR/snapshot.count"
run_reconcile env > "$TMP_DIR/reconcile.out"
grep -qx 'UNRELATED_SETTING=keep-me' "$TMP_DIR/runtime.env"
grep -qx "API_SERVER_KEY=$secret_key" "$TMP_DIR/runtime.env"
[[ "$(grep -c '^API_SERVER_KEY=' "$TMP_DIR/runtime.env")" == 1 ]]
[[ "$(stat -c %a "$TMP_DIR/runtime.env")" == 600 ]]
! grep -Fq "$secret_key" "$TMP_DIR/reconcile.out"
! grep -Fq "$secret_key" "$TMP_DIR/kubectl.calls"
for app in hermes-agent hermes-dashboard hermes-webui; do
  grep -Fq "patch deployment $app" "$TMP_DIR/kubectl.calls"
  grep -Fq "rollout status deploy/$app --timeout=600s" "$TMP_DIR/kubectl.calls"
  grep -Fq "exec $app-pod" "$TMP_DIR/kubectl.calls"
done
! grep -Fq 'rollout restart' "$TMP_DIR/kubectl.calls"
[[ "$(grep -c 'delete pod hermes-api-key-reconcile' "$TMP_DIR/kubectl.calls")" -ge 2 ]]
grep -Fq 'Internal API key reconciled from Kubernetes Secret; all enabled consumers authenticate successfully.' "$TMP_DIR/reconcile.out"

printf '%s\n' 'API_SERVER_KEY=stale-before-rotation' > "$TMP_DIR/runtime.env"
: > "$TMP_DIR/rotation.calls"
printf '0' > "$TMP_DIR/snapshot.count"
run_reconcile env FAKE_ROTATE_ONCE=true FAKE_KUBECTL_CALLS="$TMP_DIR/rotation.calls" > "$TMP_DIR/rotation.out" 2>&1
grep -qx "API_SERVER_KEY=$secret_key" "$TMP_DIR/runtime.env"
[[ "$(grep -c 'get secret hermes-api-server -o json$' "$TMP_DIR/rotation.calls")" == 2 ]]
grep -Fq 'api-key-revision' "$TMP_DIR/rotation.calls"
grep -Fq 'rv-secret-current' "$TMP_DIR/rotation.calls"
! grep -Fq 'rv-secret-superseded' "$TMP_DIR/rotation.calls"
grep -Fq 'changed during reconciliation attempt 1' "$TMP_DIR/rotation.out"

printf '%s\n' 'UNRELATED_SETTING=keep-preflight' 'API_SERVER_KEY=stale-preflight' > "$TMP_DIR/runtime.env"
: > "$TMP_DIR/preflight.calls"
printf '0' > "$TMP_DIR/snapshot.count"
if run_reconcile env FAKE_MISSING_DEPLOYMENT=hermes-dashboard FAKE_KUBECTL_CALLS="$TMP_DIR/preflight.calls" >/dev/null 2>&1; then
  printf 'missing deployment preflight unexpectedly succeeded\n' >&2
  exit 1
fi
grep -qx 'API_SERVER_KEY=stale-preflight' "$TMP_DIR/runtime.env"
! grep -Fq 'apply -f -' "$TMP_DIR/preflight.calls"
! grep -Fq 'patch deployment' "$TMP_DIR/preflight.calls"

printf '%s\n' 'API_SERVER_KEY=stale-before-patch-failure' > "$TMP_DIR/runtime.env"
: > "$TMP_DIR/patch-failure.calls"
printf '0' > "$TMP_DIR/snapshot.count"
if run_reconcile env FAKE_PATCH_FAIL_APP=hermes-dashboard FAKE_KUBECTL_CALLS="$TMP_DIR/patch-failure.calls" >/dev/null 2>&1; then
  printf 'injected deployment patch failure unexpectedly succeeded\n' >&2
  exit 1
fi
grep -qx "API_SERVER_KEY=$secret_key" "$TMP_DIR/runtime.env"
grep -Fq 'patch deployment hermes-agent' "$TMP_DIR/patch-failure.calls"
grep -Fq 'patch deployment hermes-dashboard' "$TMP_DIR/patch-failure.calls"
! grep -Fq 'patch deployment hermes-webui' "$TMP_DIR/patch-failure.calls"
! grep -Fq 'rollout status' "$TMP_DIR/patch-failure.calls"
grep -Fq 'delete pod hermes-api-key-reconcile' "$TMP_DIR/patch-failure.calls"

: > "$TMP_DIR/retry.calls"
printf '0' > "$TMP_DIR/snapshot.count"
run_reconcile env FAKE_KUBECTL_CALLS="$TMP_DIR/retry.calls" >/dev/null
for app in hermes-agent hermes-dashboard hermes-webui; do
  grep -Fq "patch deployment $app" "$TMP_DIR/retry.calls"
  grep -Fq "rollout status deploy/$app --timeout=600s" "$TMP_DIR/retry.calls"
done

: > "$TMP_DIR/invalid.calls"
if PATH="$TMP_DIR/bin:$PATH" ENV_FILE=/dev/null FAKE_KUBECTL_CALLS="$TMP_DIR/invalid.calls" \
  "$ROOT_DIR/maintain.sh" reconcile-api-key --source persistent >/dev/null 2>&1; then
  printf 'unsupported reconciliation source unexpectedly accepted\n' >&2
  exit 1
fi
[[ ! -s "$TMP_DIR/invalid.calls" ]]

: > "$TMP_DIR/failure.calls"
if run_reconcile env FAKE_AUTH_FAIL_APP=hermes-webui FAKE_KUBECTL_CALLS="$TMP_DIR/failure.calls" >/dev/null 2>&1; then
  printf 'failed consumer authentication unexpectedly accepted\n' >&2
  exit 1
fi
grep -Fq 'delete pod hermes-api-key-reconcile' "$TMP_DIR/failure.calls"

printf 'API-key reconciliation tests passed\n'
