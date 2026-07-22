#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ENV_FILE="$ROOT_DIR/hermes.env"
if [[ ! -f "$DEFAULT_ENV_FILE" && -f "$ROOT_DIR/current_config/hermes.env" ]]; then
  DEFAULT_ENV_FILE="$ROOT_DIR/current_config/hermes.env"
fi
ENV_FILE="${ENV_FILE:-$DEFAULT_ENV_FILE}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
HERMES_BOOTSTRAP_PROFILE="${HERMES_BOOTSTRAP_PROFILE-personal-assistant}"
if [[ -n "$HERMES_BOOTSTRAP_PROFILE" ]]; then
  profile_dir="$ROOT_DIR/examples/bootstrap-profiles/$HERMES_BOOTSTRAP_PROFILE"
  profile_defaults="$profile_dir/defaults.conf"
  if [[ -f "$profile_defaults" ]]; then
    # shellcheck disable=SC1090
    source "$profile_defaults"
    HERMES_ANSIBLE_SETUP="${HERMES_ANSIBLE_SETUP-${HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP:-false}}"
    HERMES_SSH_SETUP="${HERMES_SSH_SETUP-${HERMES_PROFILE_DEFAULT_SSH_SETUP:-true}}"
    if [[ -z "${HERMES_ADDON_REQUIREMENTS+x}" && -n "${HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS:-}" ]]; then
      HERMES_ADDON_REQUIREMENTS="$profile_dir/$HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS"
    fi
  fi
fi
if [[ -z "${HERMES_ANSIBLE_CONFIG+x}" ]]; then
  if [[ "${HERMES_ANSIBLE_SETUP:-false}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
    HERMES_ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg
  else
    HERMES_ANSIBLE_CONFIG=
  fi
fi
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
HERMES_RUNTIME_UID="${HERMES_RUNTIME_UID:-10000}"
HERMES_RUNTIME_GID="${HERMES_RUNTIME_GID:-10000}"
HERMES_DASHBOARD_ENABLED="${HERMES_DASHBOARD_ENABLED:-true}"
HERMES_WEBUI_ENABLED="${HERMES_WEBUI_ENABLED:-true}"
HERMES_BROWSER_ENABLED="${HERMES_BROWSER_ENABLED:-true}"
WEBUI_HOST="${WEBUI_HOST:-}"
DASHBOARD_HOST="${DASHBOARD_HOST:-}"

ok() { printf '\033[1;32mOK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
fail_count=0
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail_count=$((fail_count+1)); }

check_cmd() { command -v "$1" >/dev/null 2>&1 && ok "command $1" || fail "missing command $1"; }

is_truthy() { [[ "${1:-}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; }
enabled_apps() {
  printf '%s\n' hermes-agent
  is_truthy "$HERMES_DASHBOARD_ENABLED" && printf '%s\n' hermes-dashboard
  is_truthy "$HERMES_WEBUI_ENABLED" && printf '%s\n' hermes-webui
}
enabled_deployments() {
  enabled_apps
  is_truthy "$HERMES_BROWSER_ENABLED" && printf '%s\n' hermes-browser
}

check_k8s() {
  kubectl cluster-info >/dev/null 2>&1 && ok "kubectl can reach cluster" || fail "kubectl cannot reach cluster"
  kubectl get ns "$HERMES_NAMESPACE" >/dev/null 2>&1 && ok "namespace $HERMES_NAMESPACE exists" || fail "namespace $HERMES_NAMESPACE missing"
}

check_rollouts() {
  local d
  while IFS= read -r d; do
    if kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=5s >/dev/null 2>&1; then
      ok "deployment $d ready"
    else
      fail "deployment $d not ready"
    fi
  done < <(enabled_deployments)
}

check_internal_health() {
  local image="curlimages/curl:8.11.1" commands
  commands='set -e; curl -fsS http://hermes-agent:8642/health >/dev/null'
  is_truthy "$HERMES_WEBUI_ENABLED" && commands+='; curl -fsS http://hermes-webui:8787/health >/dev/null'
  is_truthy "$HERMES_DASHBOARD_ENABLED" && commands+='; curl -fsS -o /dev/null -w "%{http_code}" http://hermes-dashboard:9119/ | grep -Eq "^(200|302)$"'
  if kubectl -n "$HERMES_NAMESPACE" run hermes-doctor-curl --rm -i --restart=Never --image="$image" -- sh -lc "$commands" >/dev/null 2>&1; then
    ok "internal service health"
  else
    fail "internal service health failed"
  fi
}

check_browser_cdp() {
  is_truthy "$HERMES_BROWSER_ENABLED" || return 0
  local app pod env_cdp browser_pod cdp token pressure pressure_state running max_concurrent queued is_available timeout_seconds
  timeout_seconds="${DOCTOR_CDP_TIMEOUT_SECONDS:-45}"

  browser_pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-browser --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  cdp="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-cdp -o jsonpath='{.data.BROWSER_CDP_URL}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  token="${cdp##*token=}"

  if [[ "$cdp" == ws://hermes-browser:3000/chromium\?token=* && -n "$token" && "$token" != "$cdp" ]]; then
    ok "Browserless CDP Secret uses ws://hermes-browser:3000/chromium?token=<redacted>"
  else
    fail "Browserless CDP Secret must be ws://hermes-browser:3000/chromium?token=<redacted>"
    return
  fi

  if kubectl -n "$HERMES_NAMESPACE" get svc hermes-browser >/dev/null 2>&1 && \
     kubectl -n "$HERMES_NAMESPACE" get endpoints hermes-browser -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
    ok "Browserless Service has ready endpoints"
  else
    fail "Browserless Service has no ready endpoints"
  fi

  if [[ -n "$browser_pod" ]]; then
    pressure="$(timeout 8s kubectl -n "$HERMES_NAMESPACE" exec "$browser_pod" -- sh -lc 'TOKEN="$0"; wget -qO- "http://127.0.0.1:3000/pressure?token=$TOKEN"' "$token" 2>/dev/null || true)"
    if [[ -n "$pressure" ]]; then
      pressure_state="$(PRESSURE_JSON="$pressure" python3 - <<'PY'
import json, os
try:
    p=json.loads(os.environ.get('PRESSURE_JSON','{}')).get('pressure', {})
    print(p.get('running', ''), p.get('maxConcurrent', ''), p.get('queued', ''), str(p.get('isAvailable', '')).lower())
except Exception:
    print('', '', '', '')
PY
)"
      read -r running max_concurrent queued is_available <<<"$pressure_state"
      if [[ "$is_available" == "true" ]]; then
        ok "browserless pressure available running=${running:-?} max=${max_concurrent:-?} queued=${queued:-?}"
      else
        warn "browserless pressure not available running=${running:-?} max=${max_concurrent:-?} queued=${queued:-?}"
      fi
      if [[ "${max_concurrent:-}" =~ ^[0-9]+$ && "$max_concurrent" -lt 4 ]]; then
        warn "browserless maxConcurrent=${max_concurrent}; recommended minimum is 4 for parallel Hermes browser workflows"
      fi
    else
      fail "browserless /pressure endpoint not reachable from browser pod"
    fi
  else
    fail "no running hermes-browser pod"
  fi

  for app in $(enabled_apps); do
    pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app="$app" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "$pod" ]] || { fail "no running $app pod for CDP check"; continue; }

    env_cdp="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'printf %s "${BROWSER_CDP_URL:-}"' 2>/dev/null || true)"
    if [[ "$env_cdp" == "$cdp" ]]; then
      ok "$app BROWSER_CDP_URL matches Secret"
    else
      fail "$app BROWSER_CDP_URL missing or does not match Secret"
      continue
    fi

    if timeout "${timeout_seconds}s" kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc '
      set -eu
      PY="$(command -v python3 || command -v python || true)"
      [ -n "$PY" ] || PY="/opt/hermes/.venv/bin/python"
      [ -x "$PY" ] || PY="/app/venv/bin/python"
      "$PY" - <<"PY"
import base64, os, socket, sys
from urllib.parse import urlparse, parse_qs
url=os.environ.get("BROWSER_CDP_URL", "").strip()
if not url:
    raise SystemExit("BROWSER_CDP_URL unset")
p=urlparse(url)
if p.scheme != "ws" or p.hostname != "hermes-browser" or p.port != 3000 or p.path != "/chromium":
    raise SystemExit("invalid CDP URL shape")
token=parse_qs(p.query).get("token", [""])[0]
if not token:
    raise SystemExit("missing token")
# Browserless HTTP control endpoint: validates service DNS, TCP, token, and Browserless responsiveness.
req=(f"GET /pressure?token={token} HTTP/1.1\r\nHost: {p.hostname}:3000\r\nConnection: close\r\n\r\n").encode()
with socket.create_connection((p.hostname, p.port), timeout=10) as s:
    s.settimeout(10)
    s.sendall(req)
    data=s.recv(256)
if b" 200 " not in data.split(b"\r\n", 1)[0]:
    raise SystemExit("pressure endpoint did not return HTTP 200")
# Real WebSocket opening handshake against the configured /chromium CDP endpoint.
key=base64.b64encode(os.urandom(16)).decode()
path=p.path + "?" + p.query
req=(f"GET {path} HTTP/1.1\r\nHost: {p.hostname}:3000\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode()
with socket.create_connection((p.hostname, p.port), timeout=20) as s:
    s.settimeout(20)
    s.sendall(req)
    data=s.recv(512)
status=data.split(b"\r\n", 1)[0]
if b" 101 " not in status:
    raise SystemExit("websocket handshake failed: " + status.decode("latin1", "replace"))
print("ok")
PY
    ' >/dev/null 2>&1; then
      ok "$app CDP HTTP control endpoint and WebSocket handshake"
    else
      fail "$app CDP HTTP control endpoint or WebSocket handshake failed/timed out after ${timeout_seconds}s"
    fi
  done
}

check_home_ssh() {
  local app pod home xdg_config xdg_cache ansible_config ssh_setup key_path ssh_dir_mode key_mode pub_mode
  for app in $(enabled_apps); do
    pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app="$app" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "$pod" ]] || { fail "no running $app pod for HOME/SSH check"; continue; }

    home="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'printf %s "${HOME:-}"' 2>/dev/null || true)"
    xdg_config="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'printf %s "${XDG_CONFIG_HOME:-}"' 2>/dev/null || true)"
    xdg_cache="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'printf %s "${XDG_CACHE_HOME:-}"' 2>/dev/null || true)"
    ansible_config="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'printf %s "${ANSIBLE_CONFIG:-}"' 2>/dev/null || true)"

    if [[ "$home" == "/opt/data" && "$xdg_config" == "/opt/data/.config" && "$xdg_cache" == "/opt/data/.cache" ]]; then
      ok "$app HOME/XDG point to persistent /opt/data"
    else
      fail "$app HOME/XDG are not persistent (HOME=${home:-unset}, XDG_CONFIG_HOME=${xdg_config:-unset}, XDG_CACHE_HOME=${xdg_cache:-unset})"
    fi

    if [[ "${HERMES_ANSIBLE_SETUP:-false}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ && -n "$HERMES_ANSIBLE_CONFIG" && "$ansible_config" == "$HERMES_ANSIBLE_CONFIG" ]]; then
      ok "$app ANSIBLE_CONFIG matches configured path"
    elif [[ ! "${HERMES_ANSIBLE_SETUP:-false}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ && -z "$ansible_config" ]]; then
      ok "$app ANSIBLE_CONFIG disabled for selected profile"
    else
      fail "$app ANSIBLE_CONFIG invalid (${ansible_config:-unset})"
    fi

    ssh_setup="${HERMES_SSH_SETUP:-true}"
    [[ "$ssh_setup" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]] || continue

    ssh_dir_mode="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'test -d /opt/data/.ssh && stat -c %a /opt/data/.ssh' 2>/dev/null || true)"
    if [[ "$ssh_dir_mode" == "700" ]]; then
      ok "$app persistent SSH directory /opt/data/.ssh mode 700"
    else
      fail "$app persistent SSH directory invalid or wrong mode (${ssh_dir_mode:-missing})"
    fi

    key_path="${HERMES_SSH_KEY_PATH:-/opt/data/.ssh/id_ed25519}"
    key_mode="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'p="$0"; test -s "$p" && stat -c %a "$p"' "$key_path" 2>/dev/null || true)"
    pub_mode="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'p="$0.pub"; test -s "$p" && stat -c %a "$p"' "$key_path" 2>/dev/null || true)"
    if [[ "$key_mode" == "600" && "$pub_mode" == "644" ]]; then
      ok "$app persistent SSH keypair exists with safe modes"
    else
      fail "$app persistent SSH keypair missing or wrong modes (private=${key_mode:-missing}, public=${pub_mode:-missing})"
    fi
  done
}

check_webui_agent_source() {
  is_truthy "$HERMES_WEBUI_ENABLED" || return 0
  local pod
  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-webui --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { fail "no running hermes-webui pod"; return; }
  if kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'test -f /home/hermeswebui/.hermes/hermes-agent/run_agent.py && test -n "$BROWSER_CDP_URL"' >/dev/null 2>&1; then
    ok "webui agent source mount and BROWSER_CDP_URL"
  else
    fail "webui agent source mount or BROWSER_CDP_URL missing"
  fi
}



check_addon_python_runtime() {
  [[ -n "${HERMES_ADDON_REQUIREMENTS:-}" ]] || is_truthy "${HERMES_ANSIBLE_SETUP:-false}" || return 0
  local app pod py_out ansible_out
  for app in $(enabled_apps); do
    pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app="$app" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "$pod" ]] || { fail "no running $app pod for addon Python check"; continue; }
    py_out="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'test -x /opt/data/uv/bin/uv && test -f /opt/data/addon-venv/.hermes-uv-managed && /opt/data/addon-venv/bin/python --version' 2>/dev/null || true)"
    if [[ "$py_out" == Python\ * ]]; then
      ok "$app uv-managed addon Python ${py_out#Python }"
    else
      fail "$app uv-managed addon Python missing or broken"
    fi
    [[ "${HERMES_ANSIBLE_SETUP:-false}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]] || continue
    ansible_out="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c 'if [ -x /opt/data/addon-venv/bin/ansible ]; then /opt/data/addon-venv/bin/ansible --version | sed -n "1p"; fi' 2>/dev/null || true)"
    if [[ "$ansible_out" == ansible\ * ]]; then
      ok "$app addon Ansible available (${ansible_out})"
    else
      fail "$app addon Ansible missing or broken"
      continue
    fi
    if kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- setpriv --reuid="$HERMES_RUNTIME_UID" --regid="$HERMES_RUNTIME_GID" --clear-groups env HOME=/opt/data/home /bin/bash -l -c 'ansible localhost -m ping -i localhost, -c local' >/dev/null 2>&1; then
      ok "$app addon Ansible localhost ping"
    else
      fail "$app addon Ansible localhost ping failed"
    fi
  done

  is_truthy "$HERMES_WEBUI_ENABLED" || return 0

  # A direct kubectl exec inherits the Pod PATH and can pass while Hermes'
  # login-shell snapshot has already lost the addon paths. First verify the
  # exact subprocess HOME selected by Hermes in containers.
  if kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-webui -- setpriv --reuid="$HERMES_RUNTIME_UID" --regid="$HERMES_RUNTIME_GID" --clear-groups env HOME=/opt/data/home EXPECTED_ANSIBLE_CONFIG="$HERMES_ANSIBLE_CONFIG" /bin/bash -l -c 'set -eu; test "$(command -v ansible)" = /opt/data/addon-venv/bin/ansible; test "${ANSIBLE_CONFIG:-}" = "$EXPECTED_ANSIBLE_CONFIG"' >/dev/null 2>&1; then
    ok "hermes-webui subprocess HOME login shell preserves addon PATH/config"
  else
    fail "hermes-webui subprocess HOME login shell loses addon PATH/config"
  fi

  # Exercise the installed LocalEnvironment/terminal_tool implementation used
  # by WebUI chat turns, from outside the copied source checkout.
  local terminal_out
  terminal_out="$(kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-webui -- setpriv --reuid="$HERMES_RUNTIME_UID" --regid="$HERMES_RUNTIME_GID" --clear-groups env HOME=/opt/data/home EXPECTED_ANSIBLE_CONFIG="$HERMES_ANSIBLE_CONFIG" /bin/bash -lc '
    set -eu
    cd /tmp
    /app/venv/bin/python - <<"PY"
import json
import os
import shlex
from tools.terminal_tool import terminal_tool

expected_config = shlex.quote(os.environ["EXPECTED_ANSIBLE_CONFIG"])
result = json.loads(terminal_tool(
    command=(
        "set -eu; "
        "test \"$(command -v ansible)\" = /opt/data/addon-venv/bin/ansible; "
        f"test \"${{ANSIBLE_CONFIG:-}}\" = {expected_config}; "
        "ansible localhost -m ping -i localhost, -c local"
    ),
    task_id=f"doctor-webui-addon-shell-{os.getpid()}",
))
print(result.get("output", ""))
raise SystemExit(0 if result.get("exit_code") == 0 else 1)
PY
  ' 2>/dev/null || true)"
  if [[ "$terminal_out" == *'"ping": "pong"'* ]]; then
    ok "hermes-webui terminal tool preserves addon Ansible PATH/config"
  else
    fail "hermes-webui terminal tool cannot execute addon Ansible through its login-shell snapshot"
  fi
}

check_dashboard_workspace_root() {
  is_truthy "$HERMES_DASHBOARD_ENABLED" || return 0
  local pod root roots
  pod=$(kubectl -n "$HERMES_NAMESPACE" get pod -l app=hermes-dashboard --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$pod" ]] || { warn "no running dashboard pod for workspace-root check"; return; }
  root=$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'printf %s "${HERMES_DASHBOARD_FILES_ROOT:-}"' 2>/dev/null || true)
  roots=$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'printf %s "${HERMES_WRITE_SAFE_ROOT:-}"' 2>/dev/null || true)
  if [[ "$root" == "/workspace" && "$roots" == *"/workspace"* ]]; then
    ok "dashboard files root is /workspace and write-safe roots include /workspace"
  else
    fail "dashboard workspace roots invalid (HERMES_DASHBOARD_FILES_ROOT=${root:-unset}, HERMES_WRITE_SAFE_ROOT=${roots:-unset})"
  fi
}

check_webui_upload_limit() {
  is_truthy "$HERMES_WEBUI_ENABLED" || return 0
  local pod expected actual
  expected="${HERMES_WEBUI_MAX_UPLOAD_MB:-220}"
  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-webui --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { fail "no running hermes-webui pod"; return; }
  actual="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc '/app/venv/bin/python - <<PY
from api.config import MAX_UPLOAD_BYTES
print(MAX_UPLOAD_BYTES // 1024 // 1024)
PY' 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    ok "WebUI upload limit ${actual}MiB"
  else
    fail "WebUI upload limit expected ${expected}MiB but got '${actual:-unknown}'"
  fi
}

check_external() {
  if [[ -n "$WEBUI_HOST" ]]; then
    local code
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://$WEBUI_HOST/" 2>/dev/null || true)"
    [[ "$code" =~ ^(200|301|302|401)$ ]] && ok "external WebUI HTTP $code" || warn "external WebUI returned '$code'"
  fi
  if [[ -n "$DASHBOARD_HOST" ]]; then
    local code
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://$DASHBOARD_HOST/" 2>/dev/null || true)"
    [[ "$code" =~ ^(200|301|302|401)$ ]] && ok "external Dashboard HTTP $code" || warn "external Dashboard returned '$code'"
  fi
}

check_codex_auth() {
  local pod
  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-agent --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || return
  if kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'test -s /opt/data/auth.json' >/dev/null 2>&1; then
    ok "Codex/OAuth auth.json exists"
  else
    warn "Codex/OAuth auth.json absent; run: kubectl -n $HERMES_NAMESPACE exec -it deploy/hermes-agent -- hermes model"
  fi
}

main() {
  check_cmd kubectl
  check_cmd curl
  check_cmd timeout
  check_k8s
  check_rollouts
  check_internal_health
  check_home_ssh
  check_webui_agent_source
  check_addon_python_runtime
  check_dashboard_workspace_root
  check_webui_upload_limit
  check_browser_cdp
  check_external
  check_codex_auth
  if [[ "$fail_count" -gt 0 ]]; then
    printf '\n%s check(s) failed.\n' "$fail_count" >&2
    exit 1
  fi
  printf '\nAll mandatory checks passed.\n'
}
main "$@"
