#!/usr/bin/env bash
# Purpose: Test API-key rollout revision rendering and redacted drift diagnostics.
# Scope: Exercise installer rendering and doctor checks without contacting a cluster.
# Requirements: Bash, Python 3, and PyYAML.
# Usage: ./tests/api-key-convergence.sh
# Exit status: 0 means convergence contracts passed; non-zero identifies a failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-api-key-convergence.XXXXXX)"
server_pid=''
cleanup() {
  [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
mkdir -p "$TMP_DIR/bin"

old_api_key=$(printf '%s' test-api-key-before-interruption)
api_key=$(printf '%s' test-api-key-after-interruption)
old_revision=rv-before-interruption
expected_revision=rv-after-interruption

render_with_key() {
  local key="$1" revision="$2" output="$3" render_dir="$4"
  (
    export HERMES_INSTALL_LIB_ONLY=true
    export HERMES_RENDER_DIR="$render_dir"
    export HERMES_BOOTSTRAP_PROFILE= HERMES_BOOTSTRAP_MODE=disabled
    export HERMES_DASHBOARD_ENABLED=true HERMES_WEBUI_ENABLED=true HERMES_BROWSER_ENABLED=false
    export HERMES_NAMESPACE=hermes WEBUI_HOST=webui.example.com DASHBOARD_HOST=dashboard.example.com
    export API_SERVER_KEY="$key" DASHBOARD_AUTH_PASSWORD=test-dashboard-password BROWSER_TOKEN=
    export API_SERVER_KEY_REVISION="$revision"
    # shellcheck disable=SC1090
    source "$ROOT_DIR/install.sh"
    prepare_paths
    prepare_defaults
    resolve_runtime_credentials
    render_manifest
    cp "$MANIFEST_OUT" "$output"
  )
}

old_rendered="$TMP_DIR/hermes-old.yaml"
rendered="$TMP_DIR/hermes-new.yaml"
render_with_key "$old_api_key" "$old_revision" "$old_rendered" "$TMP_DIR/render-old"
render_with_key "$api_key" "$expected_revision" "$rendered" "$TMP_DIR/render-new"

python3 - "$old_rendered" "$rendered" "$expected_revision" <<'PY'
import sys, yaml
old_path, new_path, expected = sys.argv[1:]
annotation = 'kube-hermes-setup.example.com/api-key-revision'

def revisions(path):
    docs = [doc for doc in yaml.safe_load_all(open(path)) if doc]
    return {
        doc['metadata']['name']: doc['spec']['template']['metadata']['annotations'][annotation]
        for doc in docs
        if doc.get('kind') == 'Deployment' and doc['metadata']['name'] in {
            'hermes-agent', 'hermes-dashboard', 'hermes-webui'
        }
    }

old = revisions(old_path)
new = revisions(new_path)
assert set(old) == {'hermes-agent', 'hermes-dashboard', 'hermes-webui'}
assert set(new) == set(old)
assert len(set(old.values())) == 1
assert len(set(new.values())) == 1
assert set(new.values()) == {expected}
assert set(old.values()) == {'rv-before-interruption'}
assert old != new, 'a Secret resource version change must update every consuming Pod template on installer rerun'
PY

python3 - "$rendered" <<'PY'
import sys, yaml
documents = [doc for doc in yaml.safe_load_all(open(sys.argv[1])) if doc]
job = next(doc for doc in documents if doc.get('kind') == 'Job' and doc.get('metadata', {}).get('name') == 'hermes-init-config')
container = job['spec']['template']['spec']['containers'][0]
env = {item['name']: item for item in container['env']}
assert env['API_SERVER_KEY']['valueFrom']['secretKeyRef'] == {'name': 'hermes-api-server', 'key': 'api-key'}
script = container['args'][0]
assert 'upsert_runtime_env API_SERVER_KEY "$API_SERVER_KEY"' in script
assert 'upsert_runtime_env BROWSER_CDP_URL "$BROWSER_CDP_URL"' in script
assert 'umask 077' in script
assert 'mktemp /opt/data/.env.XXXXXX' in script
assert 'chown 10000:10000 "$tmp_env"' in script
assert 'mv -f "$tmp_env" /opt/data/.env' in script
assert 'cat "$tmp_env" > /opt/data/.env' not in script
assert 'chmod 600 /opt/data/.env' in script
PY

runtime_env="$TMP_DIR/runtime.env"
printf '%s\n' \
  'UNRELATED_SETTING=keep-me' \
  'API_SERVER_KEY=stale-one' \
  'BROWSER_CDP_URL=stale-browser' \
  'API_SERVER_KEY=stale-duplicate' > "$runtime_env"
python3 - "$rendered" "$TMP_DIR/upsert-runtime-env.sh" "$runtime_env" <<'PY'
import shlex, sys, yaml
rendered, output, runtime_env = sys.argv[1:]
documents = [doc for doc in yaml.safe_load_all(open(rendered)) if doc]
job = next(doc for doc in documents if doc.get('kind') == 'Job' and doc.get('metadata', {}).get('name') == 'hermes-init-config')
script = job['spec']['template']['spec']['containers'][0]['args'][0]
start = script.index('upsert_runtime_env() {')
end = script.index('chmod 600 /opt/data/.env', start) + len('chmod 600 /opt/data/.env')
snippet = script[start:end].replace('/opt/data/.env', shlex.quote(runtime_env))
open(output, 'w').write('set -eu\n' + snippet + '\n')
PY
API_SERVER_KEY="$api_key" BROWSER_CDP_URL='ws://hermes-browser:3000/chromium?token=test-browser-token' \
  sh "$TMP_DIR/upsert-runtime-env.sh" > "$TMP_DIR/upsert.stdout" 2> "$TMP_DIR/upsert.stderr"
grep -qx 'UNRELATED_SETTING=keep-me' "$runtime_env"
grep -qx "API_SERVER_KEY=$api_key" "$runtime_env"
grep -qx 'BROWSER_CDP_URL=ws://hermes-browser:3000/chromium?token=test-browser-token' "$runtime_env"
[[ "$(grep -c '^API_SERVER_KEY=' "$runtime_env")" == 1 ]]
[[ "$(grep -c '^BROWSER_CDP_URL=' "$runtime_env")" == 1 ]]
[[ "$(stat -c %a "$runtime_env")" == 600 ]]
[[ ! -s "$TMP_DIR/upsert.stdout" && ! -s "$TMP_DIR/upsert.stderr" ]]
! grep -Fq "$api_key" "$rendered"
! grep -Fq "$old_api_key" "$old_rendered"

pre_init_manifest="$(
  HERMES_INSTALL_LIB_ONLY=true HERMES_RENDER_DIR="$TMP_DIR/render-new" \
  bash -c 'source "$1"; prepare_paths; printf %s "$(render_pre_init_manifest)"' _ "$ROOT_DIR/install.sh"
)"
python3 - "$pre_init_manifest" <<'PY'
import sys, yaml
documents = [doc for doc in yaml.safe_load_all(open(sys.argv[1])) if doc]
assert any(doc.get('kind') == 'Job' and doc.get('metadata', {}).get('name') == 'hermes-init-config' for doc in documents)
assert not any(doc.get('kind') == 'Deployment' for doc in documents)
PY
python3 - "$ROOT_DIR/install.sh" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
body = text.split('apply_and_wait() {', 1)[1].split('\n}', 1)[0]
assert body.index('kubectl apply -f "$pre_init_manifest"') < body.index('wait --for=condition=complete job/hermes-init-config')
assert body.index('delete deploy,svc,ingress hermes-dashboard') < body.index('wait --for=condition=complete job/hermes-init-config')
assert body.index('delete deploy,svc,ingress hermes-webui') < body.index('wait --for=condition=complete job/hermes-init-config')
assert body.index('delete deploy,svc hermes-browser') < body.index('wait --for=condition=complete job/hermes-init-config')
assert body.index('wait --for=condition=complete job/hermes-init-config') < body.index('kubectl apply -f "$MANIFEST_OUT"')
assert 'deployment_template_digest' in body and 'template_before' in body and 'restart_deployments' in body
assert 'generation_before' not in body
PY

server_info="$TMP_DIR/health-server"
python3 - "$api_key" "$server_info" <<'PY' &
import http.server, pathlib, sys
expected, info_path = sys.argv[1:]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        valid = self.path == '/health/detailed' and self.headers.get('Authorization') == f'Bearer {expected}'
        self.send_response(200 if valid else 401)
        self.end_headers()
        self.wfile.write(b'ok' if valid else b'unauthorized')
    def log_message(self, *_args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(info_path).write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$server_info" ]] && break
  sleep 0.05
done
[[ -s "$server_info" ]]
health_url="http://127.0.0.1:$(<"$server_info")"

cat > "$TMP_DIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -n && "${2:-}" == hermes ]] || { printf 'missing namespace arguments\n' >&2; exit 2; }
shift 2
case "${1:-} ${2:-}" in
  'get secret')
    [[ "$#" -eq 5 && "$3" == hermes-api-server && "$4" == -o && "$5" == 'jsonpath={.metadata.resourceVersion}' ]] || {
      printf 'unexpected Secret lookup: %s\n' "$*" >&2; exit 2;
    }
    printf '%s' "${FAKE_SECRET_REVISION:?}"
    ;;
  'get deployment')
    [[ "$#" -eq 5 && "$4" == -o && "$5" == 'go-template={{ index .spec.template.metadata.annotations "kube-hermes-setup.example.com/api-key-revision" }}' ]] || {
      printf 'unexpected Deployment lookup: %s\n' "$*" >&2; exit 2;
    }
    app="$3"
    case "$app" in hermes-agent|hermes-dashboard|hermes-webui) ;; *) exit 2 ;; esac
    if [[ "$app" == "${FAKE_DRIFT_APP:-}" ]]; then
      printf '%064d' 0
    else
      printf '%s' "${FAKE_REVISION:?}"
    fi
    ;;
  'get pods')
    [[ "$#" -eq 7 && "$3" == -l && "$4" == app=* && "$5" == --field-selector=status.phase=Running && "$6" == -o && "$7" == "jsonpath={.items[0].metadata.name}" ]] || {
      printf 'unexpected Pod lookup: %s\n' "$*" >&2; exit 2;
    }
    app="${4#app=}"
    case "$app" in hermes-agent|hermes-dashboard|hermes-webui) ;; *) exit 2 ;; esac
    printf '%s-pod' "$app"
    ;;
  'get pod')
    [[ "$#" -eq 5 && "$3" == *-pod && "$4" == -o && "$5" == 'go-template={{ index .metadata.annotations "kube-hermes-setup.example.com/api-key-revision" }}' ]] || {
      printf 'unexpected running Pod lookup: %s\n' "$*" >&2; exit 2;
    }
    app="${3%-pod}"
    case "$app" in hermes-agent|hermes-dashboard|hermes-webui) ;; *) exit 2 ;; esac
    if [[ "$app" == "${FAKE_POD_DRIFT_APP:-}" ]]; then
      printf '%s' stale-resource-version
    else
      printf '%s' "${FAKE_REVISION:?}"
    fi
    ;;
  exec\ *)
    [[ "$#" -eq 6 && "$3" == -- && "$4" == sh && "$5" == -c ]] || {
      printf 'unexpected exec invocation: %s\n' "$*" >&2; exit 2;
    }
    app="${2%-pod}"
    case "$app" in hermes-agent|hermes-dashboard|hermes-webui) ;; *) exit 2 ;; esac
    payload="$6"
    [[ "$payload" == *'/health/detailed'* && "$payload" == *'Authorization'* && "$payload" == *'print("ok")'* ]] || {
      printf 'exec payload does not validate authenticated health\n' >&2; exit 2;
    }
    key="${FAKE_API_KEY:?}"
    [[ "$app" != "${FAKE_RUNTIME_DRIFT_APP:-}" ]] || key=wrong-api-key
    case "$app" in
      hermes-webui)
        env -u API_SERVER_KEY HERMES_API_KEY="$key" HERMES_API_URL="${FAKE_HEALTH_URL:?}" sh -c "$payload"
        ;;
      hermes-dashboard)
        env -u HERMES_API_KEY -u HERMES_API_URL API_SERVER_KEY="$key" GATEWAY_HEALTH_URL="${FAKE_HEALTH_URL:?}" sh -c "$payload"
        ;;
      hermes-agent)
        env -u HERMES_API_KEY API_SERVER_KEY="$key" HERMES_API_URL="${FAKE_HEALTH_URL:?}" sh -c "$payload"
        ;;
    esac
    ;;
  *)
    printf 'unexpected kubectl call: %s\n' "$*" >&2
    exit 2
    ;;
esac
KUBECTL
chmod +x "$TMP_DIR/bin/kubectl"

resolved_revision="$(
  PATH="$TMP_DIR/bin:$PATH" FAKE_SECRET_REVISION="$expected_revision" \
  HERMES_INSTALL_LIB_ONLY=true HERMES_NAMESPACE=hermes \
  bash -c 'source "$1"; resolve_api_key_revision; printf %s "$API_SERVER_KEY_REVISION"' _ "$ROOT_DIR/install.sh"
)"
[[ "$resolved_revision" == "$expected_revision" ]]

run_doctor_check() {
  PATH="$TMP_DIR/bin:$PATH" \
  FAKE_SECRET_REVISION="${FAKE_SECRET_REVISION_OVERRIDE:-$expected_revision}" \
  FAKE_REVISION="$expected_revision" FAKE_API_KEY=$api_key FAKE_HEALTH_URL="$health_url" \
  HERMES_DOCTOR_LIB_ONLY=true HERMES_NAMESPACE=hermes HERMES_AUTH_MODE=external-oidc \
  HERMES_DASHBOARD_ENABLED=true HERMES_WEBUI_ENABLED=true \
  "$@" bash -c 'source "$1"; check_api_key_convergence; printf "fail_count=%s\n" "$fail_count"' _ "$ROOT_DIR/doctor.sh"
}

healthy_output="$(run_doctor_check env)"
for app in hermes-agent hermes-dashboard hermes-webui; do
  grep -Fq "$app API key revision matches Secret and running Pod" <<<"$healthy_output"
  grep -Fq "$app internal API bearer authentication succeeds" <<<"$healthy_output"
done
grep -Fq 'fail_count=0' <<<"$healthy_output"
! grep -Fq "$api_key" <<<"$healthy_output"

drift_output="$(run_doctor_check env FAKE_RUNTIME_DRIFT_APP=hermes-webui)"
grep -Fq 'hermes-webui internal API bearer authentication failed; external OIDC protects user login and does not replace the internal API key' <<<"$drift_output"
grep -Fq 'fail_count=1' <<<"$drift_output"
! grep -Fq "$api_key" <<<"$drift_output"
! grep -Fq 'revision drift or authenticated health failure' <<<"$drift_output"

pod_drift_output="$(run_doctor_check env FAKE_POD_DRIFT_APP=hermes-dashboard)"
grep -Fq 'hermes-dashboard running Pod API key revision does not match Secret' <<<"$pod_drift_output"
grep -Fq 'fail_count=1' <<<"$pod_drift_output"

template_drift_output="$(run_doctor_check env FAKE_DRIFT_APP=hermes-agent)"
grep -Fq 'hermes-agent Deployment API key revision does not match Secret' <<<"$template_drift_output"
grep -Fq 'fail_count=1' <<<"$template_drift_output"

unsafe_revision_output="$(FAKE_SECRET_REVISION_OVERRIDE='unsafe revision' run_doctor_check env)"
grep -Fq 'API server key Secret revision missing or unreadable' <<<"$unsafe_revision_output"
grep -Fq 'fail_count=1' <<<"$unsafe_revision_output"
! grep -Fq 'revision drift' <<<"$unsafe_revision_output"
! grep -Fq "$api_key" <<<"$unsafe_revision_output"

printf '%s\n' 'HERMES_DOCTOR_LIB_ONLY=true' > "$TMP_DIR/doctor.env"
set +e
ENV_FILE="$TMP_DIR/doctor.env" KUBECONFIG="$TMP_DIR/missing-kubeconfig" timeout 20s \
  bash "$ROOT_DIR/doctor.sh" >"$TMP_DIR/doctor-main.out" 2>&1
doctor_status=$?
set -e
[[ "$doctor_status" -ne 0 && "$doctor_status" -ne 124 ]]
grep -Eq 'FAIL|check\(s\) failed' "$TMP_DIR/doctor-main.out"

printf 'API-key convergence tests passed\n'
