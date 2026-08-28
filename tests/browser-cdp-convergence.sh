#!/usr/bin/env bash
# Purpose: Verify Secret-authoritative Browserless convergence and profile drift checks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-browser-cdp-convergence.XXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/profiles/one" "$TMP_DIR/home/profiles/two"

cat > "$TMP_DIR/bin/openssl" <<'OPENSSL'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'rand -hex 16' ]] || exit 2
printf '%s' 'ffeeddccbbaa99887766554433221100'
OPENSSL
chmod 0755 "$TMP_DIR/bin/openssl"

browser_token='test-browser-token-authoritative'
cdp_url="ws://hermes-browser:3000/chromium?token=${browser_token}"
printf '%s\n' 'UNRELATED_SETTING=keep-me' 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=stale-one' 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=stale-two' > "$TMP_DIR/home/.env"
printf '%s\n' 'PROFILE_SETTING=keep-profile' 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=stale-profile' > "$TMP_DIR/home/profiles/one/.env"
printf '%s\n' 'PROFILE_WITHOUT_OVERRIDE=keep-unchanged' > "$TMP_DIR/home/profiles/two/.env"
chmod 0640 "$TMP_DIR/home/.env" "$TMP_DIR/home/profiles/one/.env" "$TMP_DIR/home/profiles/two/.env"

cat > "$TMP_DIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_KUBECTL_CALLS:?}"
if [[ "${1:-} ${2:-} ${3:-}" == 'apply -f -' ]]; then
  manifest="$(cat)"
  grep -Fq 'name: hermes-browser-token-reconcile' <<<"$manifest"
  grep -Fq 'claimName: hermes-home' <<<"$manifest"
  grep -Fq 'automountServiceAccountToken: false' <<<"$manifest"
  exit 0
fi
[[ "${1:-}" == -n && "${2:-}" == hermes ]] || { printf 'unexpected namespace: %s\n' "$*" >&2; exit 2; }
shift 2
case "${1:-} ${2:-}" in
  'get deployment')
    case "${3:-}" in hermes-agent|hermes-dashboard|hermes-webui|hermes-browser) ;; *) exit 2 ;; esac
    ;;
  'delete pod')
    exit 0
    ;;
  'wait --for=condition=Ready')
    [[ "${3:-}" == pod/hermes-browser-token-reconcile ]] || exit 2
    ;;
  'get secret')
    if [[ "${3:-}" == hermes-browser-token && "${4:-}" == hermes-browser-cdp && "${5:-}" == -o && "${6:-}" == json ]]; then
      token="${FAKE_BROWSER_TOKEN:?}"
      url="${FAKE_CDP_URL:?}"
      if [[ "${FAKE_TOKEN_MISMATCH:-false}" == true ]]; then
        token='different-browser-token'
      elif [[ "${FAKE_UNSAFE_TOKEN:-false}" == true ]]; then
        token='unsafe;browser-token'
        url='ws://hermes-browser:3000/chromium?token=unsafe;browser-token'
      fi
      printf '{"items":[{"metadata":{"name":"hermes-browser-token","resourceVersion":"rv-token-current"},"data":{"token":"%s"}},{"metadata":{"name":"hermes-browser-cdp","resourceVersion":"rv-cdp-current"},"data":{"BROWSER_CDP_URL":"%s"}}]}\n' \
        "$(printf '%s' "$token" | base64 -w0)" "$(printf '%s' "$url" | base64 -w0)"
    elif [[ "${3:-}" == hermes-browser-token && "${4:-}" == -o && "${5:-}" == 'jsonpath={.metadata.resourceVersion}' ]]; then
      printf '%s' rv-token-current
    elif [[ "${3:-}" == hermes-browser-cdp && "${4:-}" == -o && "${5:-}" == 'jsonpath={.metadata.resourceVersion}' ]]; then
      printf '%s' rv-cdp-current
    else
      printf 'unexpected Secret lookup: %s\n' "$*" >&2
      exit 2
    fi
    ;;
  'exec -i')
    target="${3:-}"
    [[ "${4:-}" == -- && "${5:-}" == sh && "${6:-}" == -c ]] || exit 2
    payload="$7"
    if [[ "$target" == hermes-browser-token-reconcile ]]; then
      mode="${12:-write}"
      sh -c "$payload" sh "${9:-}" "${10:-}" "${FAKE_HOME:?}" "$mode"
    elif [[ "$target" == hermes-agent-pod ]]; then
      sh -c "$payload" sh "${FAKE_HOME:?}"
    else
      exit 2
    fi
    ;;
  'get pods')
    app="${4#app=}"
    [[ "${7:-}" == json ]] || exit 2
    printf '{"items":[{"metadata":{"name":"%s-pod","annotations":{"kube-hermes-setup.example.com/browser-token-revision":"rv-token-current","kube-hermes-setup.example.com/browser-cdp-revision":"rv-cdp-current","kube-hermes-setup.example.com/browser-token-reconcile-request":"ffeeddccbbaa99887766554433221100"}},"status":{"conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"ready":true}]}}]}\n' "$app"
    ;;
  'exec hermes-agent-pod'|'exec hermes-dashboard-pod'|'exec hermes-webui-pod')
    [[ "${3:-}" == -- && "${4:-}" == sh && "${5:-}" == -c ]] || exit 2
    payload="$6"
    [[ "$payload" == *'Browser.getVersion'* && "$payload" == *'BROWSER_CDP_URL'* ]] || exit 2
    [[ "${2%-pod}" != "${FAKE_CDP_FAIL_APP:-}" ]] || exit 1
    printf 'ok\n'
    ;;
  'patch deployment')
    app="$3"
    case "$app" in hermes-agent|hermes-dashboard|hermes-webui|hermes-browser) ;; *) exit 2 ;; esac
    [[ "$*" == *'browser-token-revision'* && "$*" == *'rv-token-current'* ]] || exit 2
    [[ "$*" == *'browser-cdp-revision'* && "$*" == *'rv-cdp-current'* ]] || exit 2
    [[ "$*" == *'browser-token-reconcile-request'* && "$*" == *'ffeeddccbbaa99887766554433221100'* ]] || exit 2
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
  FAKE_BROWSER_TOKEN="$browser_token" \
  FAKE_CDP_URL="$cdp_url" \
  FAKE_HOME="$TMP_DIR/home" \
  FAKE_KUBECTL_CALLS="$TMP_DIR/kubectl.calls" \
  HERMES_NAMESPACE=hermes \
  HERMES_RUNTIME_UID="$(id -u)" \
  HERMES_RUNTIME_GID="$(id -g)" \
  HERMES_DASHBOARD_ENABLED=true \
  HERMES_WEBUI_ENABLED=true \
  HERMES_BROWSER_ENABLED=true \
  "$@" "$ROOT_DIR/maintain.sh" reconcile-browser-token --source secret
}

: > "$TMP_DIR/kubectl.calls"
run_reconcile env > "$TMP_DIR/reconcile.out"
grep -qx 'UNRELATED_SETTING=keep-me' "$TMP_DIR/home/.env"
grep -qx "BROWSER_CDP_URL=$cdp_url" "$TMP_DIR/home/.env"
[[ "$(grep -c '^BROWSER_CDP_URL=' "$TMP_DIR/home/.env")" == 1 ]]
grep -qx 'PROFILE_SETTING=keep-profile' "$TMP_DIR/home/profiles/one/.env"
grep -qx "BROWSER_CDP_URL=$cdp_url" "$TMP_DIR/home/profiles/one/.env"
[[ "$(grep -c '^BROWSER_CDP_URL=' "$TMP_DIR/home/profiles/one/.env")" == 1 ]]
grep -qx 'PROFILE_WITHOUT_OVERRIDE=keep-unchanged' "$TMP_DIR/home/profiles/two/.env"
! grep -q '^BROWSER_CDP_URL=' "$TMP_DIR/home/profiles/two/.env"
[[ "$(stat -c %a "$TMP_DIR/home/.env")" == 600 ]]
[[ "$(stat -c %a "$TMP_DIR/home/profiles/one/.env")" == 600 ]]
for app in hermes-agent hermes-dashboard hermes-webui; do
  grep -Fq "patch deployment $app" "$TMP_DIR/kubectl.calls"
  grep -Fq "rollout status deploy/$app --timeout=600s" "$TMP_DIR/kubectl.calls"
  grep -Fq "exec $app-pod" "$TMP_DIR/kubectl.calls"
done
! grep -Fq 'patch deployment hermes-browser' "$TMP_DIR/kubectl.calls"
! grep -Fq "$browser_token" "$TMP_DIR/reconcile.out"
! grep -Fq "$browser_token" "$TMP_DIR/kubectl.calls"
grep -Fq 'Browserless token reconciled from Kubernetes Secrets; persistent profile state and enabled consumers are healthy.' "$TMP_DIR/reconcile.out"

: > "$TMP_DIR/identity.calls"
if run_reconcile env HERMES_RUNTIME_UID=root FAKE_KUBECTL_CALLS="$TMP_DIR/identity.calls" > "$TMP_DIR/identity.out" 2>&1; then
  printf 'non-numeric Browserless reconciliation UID unexpectedly accepted\n' >&2
  exit 1
fi
grep -Fq 'HERMES_RUNTIME_UID must be numeric' "$TMP_DIR/identity.out"
[[ ! -s "$TMP_DIR/identity.calls" ]]

printf '%s\n' 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=stale-preflight' > "$TMP_DIR/home/.env"
: > "$TMP_DIR/mismatch.calls"
if run_reconcile env FAKE_TOKEN_MISMATCH=true FAKE_KUBECTL_CALLS="$TMP_DIR/mismatch.calls" > "$TMP_DIR/mismatch.out" 2>&1; then
  printf 'mismatched Browserless Secrets unexpectedly reconciled\n' >&2
  exit 1
fi
grep -qx 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=stale-preflight' "$TMP_DIR/home/.env"
! grep -Fq 'patch deployment' "$TMP_DIR/mismatch.calls"

: > "$TMP_DIR/unsafe.calls"
if run_reconcile env FAKE_UNSAFE_TOKEN=true FAKE_KUBECTL_CALLS="$TMP_DIR/unsafe.calls" > "$TMP_DIR/unsafe.out" 2>&1; then
  printf 'dotenv-unsafe Browserless token unexpectedly reconciled\n' >&2
  exit 1
fi
grep -qx 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=stale-preflight' "$TMP_DIR/home/.env"
! grep -Fq 'patch deployment' "$TMP_DIR/unsafe.calls"

mkdir -p "$TMP_DIR/outside-profile"
printf '%s\n' 'OUTSIDE_SETTING=must-not-change' 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=outside-old' > "$TMP_DIR/outside-profile/.env"
ln -s "$TMP_DIR/outside-profile" "$TMP_DIR/home/profiles/evil"
: > "$TMP_DIR/symlink.calls"
if run_reconcile env FAKE_KUBECTL_CALLS="$TMP_DIR/symlink.calls" > "$TMP_DIR/symlink.out" 2>&1; then
  printf 'symlinked profile directory unexpectedly reconciled\n' >&2
  exit 1
fi
grep -qx 'OUTSIDE_SETTING=must-not-change' "$TMP_DIR/outside-profile/.env"
grep -qx 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=outside-old' "$TMP_DIR/outside-profile/.env"
! grep -Fq 'patch deployment' "$TMP_DIR/symlink.calls"
rm -f "$TMP_DIR/home/profiles/evil"

run_doctor_persistent_check() {
  PATH="$TMP_DIR/bin:$PATH" ENV_FILE=/dev/null FAKE_HOME="$TMP_DIR/home" FAKE_KUBECTL_CALLS="$TMP_DIR/doctor.calls" \
  HERMES_DOCTOR_LIB_ONLY=true HERMES_NAMESPACE=hermes HERMES_BROWSER_ENABLED=true \
  bash -c 'source "$1"; check_persistent_browser_cdp "$2" hermes-agent-pod; printf "fail_count=%s\n" "$fail_count"' _ "$ROOT_DIR/doctor.sh" "$cdp_url"
}
printf '%s\n' "BROWSER_CDP_URL=$cdp_url" > "$TMP_DIR/home/.env"
printf '%s\n' "BROWSER_CDP_URL=$cdp_url" > "$TMP_DIR/home/profiles/one/.env"
: > "$TMP_DIR/doctor.calls"
healthy_doctor="$(run_doctor_persistent_check)"
grep -Fq 'persistent root/profile BROWSER_CDP_URL matches Secret' <<<"$healthy_doctor"
grep -Fq 'fail_count=0' <<<"$healthy_doctor"
printf '%s\n' 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=stale-again' > "$TMP_DIR/home/profiles/one/.env"
drift_doctor="$(run_doctor_persistent_check)"
grep -Fq 'persistent root/profile BROWSER_CDP_URL missing or drifted' <<<"$drift_doctor"
grep -Fq 'fail_count=1' <<<"$drift_doctor"
! grep -Fq "$browser_token" <<<"$drift_doctor"
ln -s "$TMP_DIR/outside-profile" "$TMP_DIR/home/profiles/evil"
symlink_doctor="$(run_doctor_persistent_check)"
grep -Fq 'persistent root/profile BROWSER_CDP_URL missing or drifted' <<<"$symlink_doctor"
grep -Fq 'fail_count=1' <<<"$symlink_doctor"
rm -f "$TMP_DIR/home/profiles/evil"

rotation_probe="$TMP_DIR/rotation-probe"
ENV_FILE=/dev/null HERMES_MAINTAIN_LIB_ONLY=true HERMES_NAMESPACE=hermes \
HERMES_DASHBOARD_ENABLED=true HERMES_WEBUI_ENABLED=true HERMES_BROWSER_ENABLED=true \
BROWSER_TOKEN=rotation-test-token bash -c '
  set -euo pipefail
  source "$1"
  probe="$2"
  rand_hex() { printf "%s" fresh-generated-browser-token; }
  kubectl() {
    if [[ "$*" == *" create secret generic "* ]]; then
      if [[ "$*" == *"hermes-browser-token"* ]]; then
        for argument in "$@"; do
          case "$argument" in --from-file=token=*) cat "${argument#--from-file=token=}" > "$probe.token" ;; esac
        done
      fi
      printf "%s\n" "apiVersion: v1" "kind: Secret"
    elif [[ "$*" == "apply -f -" ]]; then
      cat >/dev/null
    else
      printf "unexpected rotation kubectl call: %s\n" "$*" >&2
      return 2
    fi
  }
  reconcile_browser_token() { printf "%s\n" "$*" > "$probe"; }
  rotate_browser_token >/dev/null
' _ "$ROOT_DIR/maintain.sh" "$rotation_probe"
grep -qx -- '--source secret --restart-browser' "$rotation_probe"
grep -qx 'fresh-generated-browser-token' "$rotation_probe.token"
! grep -Fq 'rotation-test-token' "$rotation_probe.token"

printf 'Browserless convergence tests passed\n'
