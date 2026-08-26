#!/usr/bin/env bash
# Purpose: Validate rendered Kubernetes manifests across optional-component combinations.
# Scope: Exercise Dashboard, WebUI, and Browserless enabled/disabled states and verify
#        resources, references, and security settings remain internally consistent.
# Requirements: Bash, Python 3 with PyYAML, standard utilities, and repository scripts.
# Usage: ./tests/matrix.sh
# Exit status: 0 means every component matrix case passed; non-zero identifies a failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-matrix-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

component_cases=0
# Render and validate all 2^3 optional-component combinations.
for dashboard in false true; do
  for webui in false true; do
    for browser in false true; do
      (
        set -a
        # shellcheck disable=SC1091
        source "$ROOT_DIR/examples/hermes.env.example"
        set +a
        export HERMES_INSTALL_LIB_ONLY=true
        # shellcheck disable=SC1091
        source "$ROOT_DIR/install.sh"
        export HERMES_DASHBOARD_ENABLED="$dashboard"
        export HERMES_WEBUI_ENABLED="$webui"
        export HERMES_BROWSER_ENABLED="$browser"
        export HERMES_BOOTSTRAP_MODE=disabled
        export HERMES_ADDON_REQUIREMENTS=
        export DASHBOARD_HOST=dashboard.example.com
        export WEBUI_HOST=webui.example.com
        export HERMES_RENDER_DIR="$TMP_DIR/render-$dashboard-$webui-$browser"
        prepare_paths
        prepare_defaults
        mkdir -p "$RENDER_DIR"
        python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$MANIFEST_OUT"
        python3 - "$MANIFEST_OUT" "$dashboard" "$webui" "$browser" <<'PY'
import sys
import yaml

manifest, dashboard, webui, browser = sys.argv[1:]
docs = [doc for doc in yaml.safe_load_all(open(manifest)) if doc]
resources = {(doc["kind"], doc["metadata"]["name"]) for doc in docs}
assert ("Deployment", "hermes-agent") in resources
for enabled, name in (
    (dashboard, "hermes-dashboard"),
    (webui, "hermes-webui"),
    (browser, "hermes-browser"),
):
    expected = enabled == "true"
    assert (("Deployment", name) in resources) == expected
    assert (("Service", name) in resources) == expected
assert (("Ingress", "hermes-dashboard") in resources) == (dashboard == "true")
assert (("Ingress", "hermes-webui") in resources) == (webui == "true")
assert (("NetworkPolicy", "hermes-browser-restrict") in resources) == (browser == "true")
for name in ("hermes-agent", "hermes-dashboard", "hermes-webui"):
    matches = [doc for doc in docs if doc["kind"] == "Deployment" and doc["metadata"]["name"] == name]
    if not matches:
        continue
    env = {item["name"]: item.get("value") for item in matches[0]["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["HOME"] == "/opt/data"
    assert env["CODEX_HOME"] == "/opt/data"
PY
      )
      component_cases=$((component_cases + 1))
    done
  done
done

custom_with="$TMP_DIR/custom-with.txt"
custom_without="$TMP_DIR/custom-without.txt"
printf '%s\n' 'requests' 'ansible @ https://example.com/ansible.whl' > "$custom_with"
printf '%s\n' 'requests' > "$custom_without"
profile_cases=0
# Dynamically discover all available profiles from the filesystem.
declare -a discovered_profiles=()
for profiledir in "$ROOT_DIR/examples/bootstrap-profiles/"*/; do
  [[ -d "$profiledir" ]] || continue
  discovered_profiles+=("$(basename "$profiledir")")
done
for profile in "${discovered_profiles[@]}"; do
  # Read the profile's local defaults to determine expected SSH behavior.
  profile_defaults="$ROOT_DIR/examples/bootstrap-profiles/$profile/defaults.conf"
  profile_ssh_default=true
  [[ -f "$profile_defaults" ]] && source "$profile_defaults" 2>/dev/null || true
  profile_ssh_expected="${HERMES_PROFILE_DEFAULT_SSH_SETUP:-true}"
  for ansible_setup in false true; do
    for requirements_mode in default empty custom-with custom-without; do
      (
        export HERMES_INSTALL_LIB_ONLY=true
        # shellcheck disable=SC1091
        source "$ROOT_DIR/install.sh"
        unset HERMES_ADDON_REQUIREMENTS HERMES_SSH_SETUP HERMES_SSH_GENERATE_KEY HERMES_ANSIBLE_CONFIG
        export HERMES_BOOTSTRAP_PROFILE="$profile"
        export HERMES_ANSIBLE_SETUP="$ansible_setup"
        export HERMES_ANSIBLE_VERSION=13.4.0
        export HERMES_BOOTSTRAP_MODE=overwrite
        case "$requirements_mode" in
          default) ;;
          empty) export HERMES_ADDON_REQUIREMENTS= ;;
          custom-with) export HERMES_ADDON_REQUIREMENTS="$custom_with" ;;
          custom-without) export HERMES_ADDON_REQUIREMENTS="$custom_without" ;;
        esac
        export HERMES_RENDER_DIR="$TMP_DIR/archive-$profile-$ansible_setup-$requirements_mode"
        prepare_paths
        prepare_defaults
        create_bootstrap_archive
        extract="$TMP_DIR/extract-$profile-$ansible_setup-$requirements_mode"
        mkdir -p "$extract"
        tar -xzf "$BOOTSTRAP_ARCHIVE" -C "$extract"

        if [[ "$ansible_setup" == true ]]; then
          [[ "$HERMES_SSH_SETUP" == true ]]
          [[ "$HERMES_ANSIBLE_CONFIG" == /workspace/ansible/ansible.cfg ]]
          [[ -f "$extract/workspace/ansible/ansible.cfg" ]]
          grep -qx 'remote_tmp = /opt/data/ansible/tmp' "$extract/workspace/ansible/ansible.cfg"
          [[ -f "$extract/addons/requirements.txt" ]]
          [[ "$(grep -Eci '^ansible' "$extract/addons/requirements.txt")" == 1 ]]
          grep -qx 'ansible==13.4.0' "$extract/addons/requirements.txt"
        else
          [[ ! -e "$extract/workspace/ansible" ]]
          [[ -z "$HERMES_ANSIBLE_CONFIG" ]]
          # SSH default is driven by the profile's own defaults.conf, not hardcoded.
          if [[ "$profile_ssh_expected" == true ]]; then
            [[ "$HERMES_SSH_SETUP" == true ]]
          else
            [[ "$HERMES_SSH_SETUP" == false ]]
          fi
          case "$requirements_mode" in
            custom-with)
              [[ "$(grep -Eci '^ansible' "$extract/addons/requirements.txt" || true)" == 1 ]]
              ;;
            *)
              [[ ! -f "$extract/addons/requirements.txt" ]] || ! grep -Eqi '^ansible' "$extract/addons/requirements.txt"
              ;;
          esac
        fi
      )
      profile_cases=$((profile_cases + 1))
    done
  done
done

injection_template="$TMP_DIR/injection-template.yaml"
injection_output="$TMP_DIR/injection-output.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: ${HERMES_NAMESPACE}\ndata:\n  value: "${MODEL_NAME}"\n' > "$injection_template"
if HERMES_NAMESPACE=hermes MODEL_NAME=$'bad\n  injected: true' python3 "$ROOT_DIR/scripts/render_template.py" "$injection_template" "$injection_output" >/dev/null 2>&1; then
  printf 'renderer accepted a multiline YAML value\n' >&2
  exit 1
fi
if HERMES_NAMESPACE='hermes;touch' MODEL_NAME=valid python3 "$ROOT_DIR/scripts/render_template.py" "$injection_template" "$injection_output" >/dev/null 2>&1; then
  printf 'renderer accepted an invalid namespace\n' >&2
  exit 1
fi

# External OIDC must remove every local-password environment reference and
# the Dashboard password-login rewrite path.
(
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/examples/hermes.env.example"
  set +a
  export HERMES_INSTALL_LIB_ONLY=true
  export HERMES_AUTH_MODE=external-oidc
  export HERMES_OIDC_ISSUER=https://sso.example.com
  export HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-dashboard
  export HERMES_WEBUI_OIDC_CLIENT_ID=hermes-webui
  export HERMES_WEBUI_OIDC_ALLOW_CLAIM=groups
  export HERMES_WEBUI_OIDC_ALLOW_VALUES=hermes-users
  export HERMES_DASHBOARD_PUBLIC_URL=https://dashboard.example.com
  export HERMES_WEBUI_OIDC_REDIRECT_URI=https://webui.example.com/api/auth/oidc/callback
  export HERMES_DASHBOARD_ENABLED=true HERMES_WEBUI_ENABLED=true HERMES_BROWSER_ENABLED=false
  export HERMES_BOOTSTRAP_MODE=disabled HERMES_ADDON_REQUIREMENTS=
  export DASHBOARD_HOST=dashboard.example.com WEBUI_HOST=webui.example.com
  export HERMES_RENDER_DIR="$TMP_DIR/render-external-oidc"
  source "$ROOT_DIR/install.sh"
  prepare_paths
  prepare_defaults
  mkdir -p "$RENDER_DIR"
  API_SERVER_KEY_REVISION=test-resource-version
  export API_SERVER_KEY_REVISION
  python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$MANIFEST_OUT"
  python3 - "$MANIFEST_OUT" <<'PY'
import sys
import yaml

docs = [doc for doc in yaml.safe_load_all(open(sys.argv[1])) if doc]
resources = {(doc["kind"], doc["metadata"]["name"]): doc for doc in docs}
assert ("Ingress", "hermes-dashboard-login") not in resources
for name in ("hermes-dashboard", "hermes-webui"):
    deployment = resources[("Deployment", name)]
    env_names = {item["name"] for item in deployment["spec"]["template"]["spec"]["containers"][0].get("env", [])}
    assert "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" not in env_names
    assert "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" not in env_names
    assert "HERMES_WEBUI_PASSWORD" not in env_names
assert resources[("Deployment", "hermes-dashboard")]["spec"]["template"]["spec"]["containers"][0]["env"]
PY
)

# Switching only HERMES_AUTH_MODE in the public example must fail before any
# local authentication is removed; all installation-specific OIDC values are blank.
if env -i PATH="$PATH" HOME="$HOME" ROOT_DIR="$ROOT_DIR" \
  bash -c 'set -a; source "$ROOT_DIR/examples/hermes.env.example"; set +a; export HERMES_INSTALL_LIB_ONLY=true HERMES_AUTH_MODE=external-oidc HERMES_BOOTSTRAP_PROFILE= HERMES_BOOTSTRAP_MODE=disabled HERMES_ADDON_REQUIREMENTS=; source "$ROOT_DIR/install.sh"; prepare_defaults; validate' \
  >/dev/null 2>&1; then
  printf 'public example activated external OIDC without installation-specific values\n' >&2
  exit 1
fi

# OIDC URLs fail closed when placeholders or callback hosts/paths do not match
# the configured application hosts.
if env -i PATH="$PATH" HOME="$HOME" \
  HERMES_INSTALL_LIB_ONLY=true HERMES_BOOTSTRAP_PROFILE= HERMES_BOOTSTRAP_MODE=disabled \
  HERMES_AUTH_MODE=external-oidc HERMES_DASHBOARD_ENABLED=true HERMES_WEBUI_ENABLED=true \
  HERMES_BROWSER_ENABLED=false DASHBOARD_HOST=dashboard.example.com WEBUI_HOST=webui.example.com \
  HERMES_DASHBOARD_OIDC_ISSUER=http://sso.example.com \
  HERMES_WEBUI_OIDC_ISSUER=https://sso.example.com \
  HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-dashboard HERMES_WEBUI_OIDC_CLIENT_ID=hermes-webui \
  HERMES_DASHBOARD_PUBLIC_URL=https://dashboard.example.com \
  HERMES_WEBUI_OIDC_REDIRECT_URI=https://webui.example.com/api/auth/oidc/callback \
  HERMES_WEBUI_OIDC_ALLOW_CLAIM=groups HERMES_WEBUI_OIDC_ALLOW_VALUES=hermes-users \
  bash -c 'source "$1"; prepare_defaults; validate' _ "$ROOT_DIR/install.sh" >/dev/null 2>&1; then
  printf 'external OIDC accepted a non-HTTPS issuer\n' >&2
  exit 1
fi

if env -i PATH="$PATH" HOME="$HOME" \
  HERMES_INSTALL_LIB_ONLY=true HERMES_BOOTSTRAP_PROFILE= HERMES_BOOTSTRAP_MODE=disabled \
  HERMES_AUTH_MODE=external-oidc HERMES_DASHBOARD_ENABLED=true HERMES_WEBUI_ENABLED=true \
  HERMES_BROWSER_ENABLED=false DASHBOARD_HOST=dashboard.example.com WEBUI_HOST=webui.example.com \
  HERMES_DASHBOARD_OIDC_ISSUER=https://sso.example.com \
  HERMES_WEBUI_OIDC_ISSUER=https://sso.example.com \
  HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-dashboard HERMES_WEBUI_OIDC_CLIENT_ID=hermes-webui \
  HERMES_DASHBOARD_PUBLIC_URL=https://dashboard.example.com/admin \
  HERMES_WEBUI_OIDC_REDIRECT_URI=https://webui.example.com:8443/api/auth/oidc/callback \
  HERMES_WEBUI_OIDC_ALLOW_CLAIM=groups HERMES_WEBUI_OIDC_ALLOW_VALUES=hermes-users \
  bash -c 'source "$1"; prepare_defaults; validate' _ "$ROOT_DIR/install.sh" >/dev/null 2>&1; then
  printf 'external OIDC accepted a mismatched public path/non-default callback port\n' >&2
  exit 1
fi

if HERMES_AUTH_MODE=disabled python3 "$ROOT_DIR/scripts/render_template.py" \
  "$ROOT_DIR/manifests/hermes.yaml.tpl" "$TMP_DIR/disabled-auth.yaml" >/dev/null 2>&1; then
  printf 'renderer accepted documentation-only disabled auth mode\n' >&2
  exit 1
fi

# Execute the migration reconciliation path against a fake kubectl. Prove that
# omitted password-login resources are actively pruned, and that the old local
# password Secret is deleted only after every external-OIDC rollout succeeds.
(
  export HERMES_INSTALL_LIB_ONLY=true HERMES_AUTH_MODE=external-oidc
  export HERMES_NAMESPACE=hermes HERMES_DASHBOARD_ENABLED=true
  export HERMES_WEBUI_ENABLED=true HERMES_BROWSER_ENABLED=false
  export MANIFEST_OUT="$TMP_DIR/migration-manifest.yaml"
  printf '%s\n' 'apiVersion: v1' 'kind: List' 'items: []' > "$MANIFEST_OUT"
  # shellcheck disable=SC1091
  source "$ROOT_DIR/install.sh"
  calls="$TMP_DIR/migration-kubectl.calls"
  kubectl() {
    printf '%s\n' "$*" >> "$calls"
    if [[ "${FAKE_FAIL_ROLLOUT:-false}" == true && "$*" == *'rollout status deploy/hermes-webui'* ]]; then
      return 1
    fi
  }
  render_pre_init_manifest() { printf '%s' "$MANIFEST_OUT"; }
  deployment_template_digest() { printf 'stable-template-digest'; }
  enabled_deployments() {
    printf '%s\n' hermes-agent hermes-dashboard hermes-webui
  }

  apply_and_wait
  grep -Fq -- '-n hermes delete ingress hermes-dashboard-login --ignore-not-found=true' "$calls"
  grep -Fq -- '-n hermes delete middleware hermes-dashboard-login-rewrite --ignore-not-found=true' "$calls"
  grep -Fq -- '-n hermes delete secret hermes-dashboard-auth --ignore-not-found=true' "$calls"

  last_rollout_line="$(grep -n -- '-n hermes rollout status deploy/hermes-webui --timeout=600s' "$calls" | tail -1 | cut -d: -f1)"
  secret_delete_line="$(grep -n -- '-n hermes delete secret hermes-dashboard-auth --ignore-not-found=true' "$calls" | tail -1 | cut -d: -f1)"
  [[ -n "$last_rollout_line" && -n "$secret_delete_line" ]]
  (( secret_delete_line > last_rollout_line ))

  : > "$calls"
  export FAKE_FAIL_ROLLOUT=true
  set +e
  ( set -e; apply_and_wait )
  failed_status=$?
  set -e
  (( failed_status != 0 ))
  grep -Fq -- '-n hermes rollout status deploy/hermes-webui --timeout=600s' "$calls"
  ! grep -Fq -- '-n hermes delete secret hermes-dashboard-auth --ignore-not-found=true' "$calls"
)

printf 'matrix tests passed: %d component combinations, %d profile/Ansible/requirements combinations\n' \
  "$component_cases" "$profile_cases"
