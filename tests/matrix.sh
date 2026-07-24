#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-matrix-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

component_cases=0
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
for profile in personal-assistant universal-system-architect; do
  for ansible_setup in false true; do
    for requirements_mode in default empty custom-with custom-without; do
      (
        export HERMES_INSTALL_LIB_ONLY=true
        # shellcheck disable=SC1091
        source "$ROOT_DIR/install.sh"
        export HERMES_BOOTSTRAP_PROFILE="$profile"
        export HERMES_ANSIBLE_SETUP="$ansible_setup"
        export HERMES_ANSIBLE_VERSION=13.4.0
        export HERMES_BOOTSTRAP_MODE=overwrite
        unset HERMES_ADDON_REQUIREMENTS HERMES_SSH_SETUP HERMES_SSH_GENERATE_KEY HERMES_ANSIBLE_CONFIG
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
          if [[ "$profile" == personal-assistant ]]; then
            [[ "$HERMES_SSH_SETUP" == false ]]
          else
            [[ "$HERMES_SSH_SETUP" == true ]]
          fi
          case "$requirements_mode" in
            custom-with)
              [[ "$(grep -Eci '^ansible' "$extract/addons/requirements.txt")" == 1 ]]
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

printf 'matrix tests passed: %d component combinations, %d profile/Ansible/requirements combinations\n' \
  "$component_cases" "$profile_cases"
