#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/hermes.env}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
WEBUI_HOST="${WEBUI_HOST:-}"
DASHBOARD_HOST="${DASHBOARD_HOST:-}"

ok() { printf '\033[1;32mOK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
fail_count=0
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail_count=$((fail_count+1)); }

check_cmd() { command -v "$1" >/dev/null 2>&1 && ok "command $1" || fail "missing command $1"; }

check_k8s() {
  kubectl cluster-info >/dev/null 2>&1 && ok "kubectl can reach cluster" || fail "kubectl cannot reach cluster"
  kubectl get ns "$HERMES_NAMESPACE" >/dev/null 2>&1 && ok "namespace $HERMES_NAMESPACE exists" || fail "namespace $HERMES_NAMESPACE missing"
}

check_rollouts() {
  for d in hermes-agent hermes-dashboard hermes-webui hermes-browser; do
    if kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=5s >/dev/null 2>&1; then
      ok "deployment $d ready"
    else
      fail "deployment $d not ready"
    fi
  done
}

check_internal_health() {
  local image="curlimages/curl:8.11.1"
  if kubectl -n "$HERMES_NAMESPACE" run hermes-doctor-curl --rm -i --restart=Never --image="$image" -- sh -lc '
    set -e
    curl -fsS http://hermes-agent:8642/health >/dev/null
    curl -fsS http://hermes-webui:8787/health >/dev/null
    curl -fsS -o /dev/null -w "%{http_code}" http://hermes-dashboard:9119/ | grep -Eq "^(200|302)$"
  ' >/dev/null 2>&1; then
    ok "internal service health"
  else
    fail "internal service health failed"
  fi
}

check_browser_cdp() {
  local pod
  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-agent --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { fail "no running hermes-agent pod"; return; }
  if kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc '/opt/hermes/.venv/bin/python - <<PY
from tools.browser_tool import _get_cdp_override, browser_navigate
url=_get_cdp_override()
assert url and "/chromium" in url
r=browser_navigate("https://example.com", task_id="doctor-cdp")
assert "Example Domain" in r and "cdp_override" in r
print("ok")
PY' >/dev/null 2>&1; then
    ok "browser CDP from hermes-agent"
  else
    fail "browser CDP from hermes-agent failed"
  fi
}

check_webui_agent_source() {
  local pod
  pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app=hermes-webui --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { fail "no running hermes-webui pod"; return; }
  if kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -lc 'test -f /home/hermeswebui/.hermes/hermes-agent/run_agent.py && test -n "$BROWSER_CDP_URL"' >/dev/null 2>&1; then
    ok "webui agent source mount and BROWSER_CDP_URL"
  else
    fail "webui agent source mount or BROWSER_CDP_URL missing"
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
  check_k8s
  check_rollouts
  check_internal_health
  check_webui_agent_source
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
