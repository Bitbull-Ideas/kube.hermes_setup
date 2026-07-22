#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-configure-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

profile_output="$TMP_DIR/profile-output"
printf '\n\n\n\nn\nn\nn\nn\nn\n' | \
  "$ROOT_DIR/configure.sh" --no-install \
    --config-dir "$TMP_DIR/profile-config" \
    --answers-file "$TMP_DIR/profile-answers" > "$profile_output"
grep -qx 'Bootstrap profile:' "$profile_output"
grep -qx '  1) personal-assistant' "$profile_output"
grep -qx '  2) universal-system-architect' "$profile_output"

# configure.sh sources install.sh as a function library, but must not leak that
# mode into the installer process selected at the final prompt.
if grep -A3 'source "$ROOT_DIR/install.sh"' "$ROOT_DIR/configure.sh" | grep -q '^unset HERMES_INSTALL_LIB_ONLY$'; then
  :
else
  printf 'configure.sh does not clear installer library mode\n' >&2
  exit 1
fi
grep -q 'HERMES_INSTALL_LIB_ONLY=false ENV_FILE=' "$ROOT_DIR/configure.sh"

config_one="$TMP_DIR/current-one"
answers_one="$TMP_DIR/answers-one"
printf '\n\n\n\nn\nn\nn\ny\n13.4.0\ny\n' | \
  "$ROOT_DIR/setup.sh" --no-install --config-dir "$config_one" --answers-file "$answers_one" >/dev/null

[[ -f "$config_one/hermes.env" ]]
[[ -f "$config_one/bootstrap/SOUL.md" ]]
[[ -f "$config_one/bootstrap/config.yaml" ]]
[[ ! -e "$config_one/artifacts/bootstrap-profile" ]]
[[ "$(stat -c %a "$config_one/hermes.env")" == 600 ]]
[[ "$(stat -c %a "$answers_one")" == 600 ]]
# shellcheck disable=SC1090
source "$config_one/hermes.env"
[[ "$HERMES_AGENT_ENABLED" == true ]]
[[ "$HERMES_DASHBOARD_ENABLED" == false ]]
[[ "$HERMES_WEBUI_ENABLED" == false ]]
[[ "$HERMES_BROWSER_ENABLED" == false ]]
[[ "$HERMES_ANSIBLE_SETUP" == true ]]
[[ "$HERMES_ANSIBLE_VERSION" == 13.4.0 ]]
[[ "$HERMES_SSH_SETUP" == true ]]
[[ "$HERMES_BOOTSTRAP_MODE" == overwrite ]]
[[ "$MODEL_PROVIDER" == codex ]]
[[ "$MODEL_NAME" == gpt-5.6-luna ]]
python3 - "$config_one/bootstrap/config.yaml" <<'PY'
import sys, yaml
config = yaml.safe_load(open(sys.argv[1]))
assert config["provider"] == "codex"
assert config["model"] == "gpt-5.6-luna"
assert config["terminal"]["cwd"] == "/workspace"
assert config["gateway"] == {"host": "0.0.0.0", "port": 8642}
PY
(
  export HERMES_INSTALL_LIB_ONLY=true
  # shellcheck disable=SC1090
  source "$ROOT_DIR/install.sh"
  prepare_paths
  prepare_defaults
  create_bootstrap_archive
  tar -xOf "$BOOTSTRAP_ARCHIVE" ./opt-data/config.yaml | grep -qx 'provider: codex'
)

touch "$config_one/stale-marker"
"$ROOT_DIR/setup.sh" --from-answers --no-install --config-dir "$config_one" --answers-file "$answers_one" >/dev/null
[[ ! -e "$config_one/stale-marker" ]]
[[ -f "$config_one/bootstrap/SOUL.md" ]]
grep -qx 'provider: codex' "$config_one/bootstrap/config.yaml"

unowned="$TMP_DIR/unowned"
mkdir -p "$unowned"
touch "$unowned/must-survive"
if "$ROOT_DIR/setup.sh" --from-answers --no-install --config-dir "$unowned" --answers-file "$answers_one" >/dev/null 2>&1; then
  printf 'unsafe replay unexpectedly succeeded\n' >&2
  exit 1
fi
[[ -f "$unowned/must-survive" ]]

config_two="$TMP_DIR/current-two"
answers_two="$TMP_DIR/answers-two"
printf '\n\nopenrouter\nopenai/gpt-5.6\ny\ny\ny\nchat.example.com\nadmin.example.com\noperator\n\nn\nn\nn\n' | \
  "$ROOT_DIR/configure.sh" --no-install --config-dir "$config_two" --answers-file "$answers_two" >/dev/null
# shellcheck disable=SC1090
source "$config_two/hermes.env"
[[ "$HERMES_DASHBOARD_ENABLED" == true ]]
[[ "$HERMES_WEBUI_ENABLED" == true ]]
[[ "$HERMES_BROWSER_ENABLED" == true ]]
[[ "$WEBUI_HOST" == chat.example.com ]]
[[ "$DASHBOARD_HOST" == admin.example.com ]]
[[ "$DASHBOARD_AUTH_USER" == operator ]]
[[ -z "$DASHBOARD_AUTH_PASSWORD" ]]
[[ "$HERMES_ANSIBLE_SETUP" == false ]]
[[ "$HERMES_SSH_SETUP" == false ]]
[[ "$HERMES_BOOTSTRAP_MODE" == missing ]]
[[ "$MODEL_PROVIDER" == openrouter ]]
[[ "$MODEL_NAME" == openai/gpt-5.6 ]]
grep -qx 'provider: openrouter' "$config_two/bootstrap/config.yaml"
grep -qx 'model: openai/gpt-5.6' "$config_two/bootstrap/config.yaml"

requirements="$TMP_DIR/requirements.txt"
printf '%s\n' 'Markdown' 'ansible==14.1.0' > "$requirements"
python3 "$ROOT_DIR/scripts/prepare_requirements.py" "$requirements" true 12.2.0 false
grep -qx 'ansible==12.2.0' "$requirements"
! grep -qx 'ansible==14.1.0' "$requirements"
python3 "$ROOT_DIR/scripts/prepare_requirements.py" "$requirements" false 12.2.0 true
! grep -qi '^ansible' "$requirements"
grep -qx 'Markdown' "$requirements"

printf '%s\n' 'ansible @ https://example.com/ansible.whl' 'ansible  # inline comment' > "$requirements"
python3 "$ROOT_DIR/scripts/prepare_requirements.py" "$requirements" true 12.2.0 false
[[ "$(grep -Eci '^ansible' "$requirements")" == 1 ]]
grep -qx 'ansible==12.2.0' "$requirements"

rendered="$TMP_DIR/agent-only.yaml"
export HERMES_DASHBOARD_ENABLED=false HERMES_WEBUI_ENABLED=false HERMES_BROWSER_ENABLED=false
export HERMES_NAMESPACE=hermes WEBUI_HOST= DASHBOARD_HOST= INGRESS_CLASS_NAME=traefik TRAEFIK_ENTRYPOINT=websecure
export TLS_ENABLED=true TLS_SECRET_NAME= STORAGE_CLASS_NAME= HERMES_HOME_STORAGE_SIZE=10Gi HERMES_WORKSPACE_STORAGE_SIZE=20Gi
export HERMES_RUNTIME_UID=10000 HERMES_RUNTIME_GID=10000 HERMES_AGENT_IMAGE=agent:test HERMES_WEBUI_IMAGE=webui:test HERMES_BROWSER_IMAGE=browser:test
export HERMES_BOOTSTRAP_MODE=missing HERMES_ADDON_PYTHON_MODE=uv HERMES_UV_DIR=/opt/data/uv HERMES_ADDON_VENV=/opt/data/addon-venv HERMES_ADDON_PYTHON_VERSION=3.13
export HERMES_SSH_SETUP=false HERMES_SSH_GENERATE_KEY=false HERMES_SSH_KEY_TYPE=ed25519 HERMES_SSH_KEY_PATH=/opt/data/.ssh/id_ed25519
export BROWSER_CDP_URL=ws://hermes-browser:3000/chromium HERMES_ANSIBLE_SETUP=false HERMES_ANSIBLE_CONFIG=
export MODEL_PROVIDER=codex MODEL_NAME=test HERMES_WEBUI_MAX_UPLOAD_MB=220
export HERMES_AGENT_CPU_REQUEST=100m HERMES_AGENT_MEMORY_REQUEST=256Mi HERMES_AGENT_CPU_LIMIT=1 HERMES_AGENT_MEMORY_LIMIT=1Gi
export HERMES_DASHBOARD_CPU_REQUEST=100m HERMES_DASHBOARD_MEMORY_REQUEST=96Mi HERMES_DASHBOARD_CPU_LIMIT=1 HERMES_DASHBOARD_MEMORY_LIMIT=1Gi
export HERMES_WEBUI_CPU_REQUEST=100m HERMES_WEBUI_MEMORY_REQUEST=256Mi HERMES_WEBUI_CPU_LIMIT=1 HERMES_WEBUI_MEMORY_LIMIT=1Gi
export HERMES_BROWSER_CPU_REQUEST=100m HERMES_BROWSER_MEMORY_REQUEST=128Mi HERMES_BROWSER_CPU_LIMIT=1 HERMES_BROWSER_MEMORY_LIMIT=1Gi
export API_SERVER_KEY=test BROWSER_CONCURRENT=4 BROWSER_QUEUED=10 BROWSER_TIMEOUT_MS=30000
python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$rendered"
python3 - "$rendered" <<'PY'
import sys, yaml
resources = {(d.get('kind'), d.get('metadata', {}).get('name')) for d in yaml.safe_load_all(open(sys.argv[1])) if d}
assert ('Deployment', 'hermes-agent') in resources
for name in ('hermes-dashboard', 'hermes-webui', 'hermes-browser'):
    assert ('Deployment', name) not in resources
    assert ('Service', name) not in resources
PY

printf 'configure and component tests passed\n'
