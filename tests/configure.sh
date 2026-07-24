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
grep -Fqx '  Credentials: Kubernetes Secrets only; values are not stored locally or printed' "$profile_output"

# Operational scripts prefer an existing root hermes.env, then discover the
# wizard-generated current_config/hermes.env when no root file exists.
fallback_root="$TMP_DIR/env-fallback"
mkdir -p "$fallback_root/current_config"
cp "$ROOT_DIR/install.sh" "$ROOT_DIR/maintain.sh" "$ROOT_DIR/doctor.sh" "$fallback_root/"
printf '%s\n' 'DASHBOARD_AUTH_PASSWORD=' 'BROWSER_TOKEN=' > "$fallback_root/current_config/hermes.env"
resolved_env="$(HERMES_INSTALL_LIB_ONLY=true bash -c 'source "$1/install.sh"; printf "%s" "$ENV_FILE"' _ "$fallback_root")"
[[ "$resolved_env" == "$fallback_root/current_config/hermes.env" ]]
maintain_env="$(SCRIPT_ROOT="$fallback_root" bash -c 'set -- help; source "$SCRIPT_ROOT/maintain.sh" >/dev/null; printf "%s" "$ENV_FILE"')"
[[ "$maintain_env" == "$fallback_root/current_config/hermes.env" ]]
rotation_inputs="$(DASHBOARD_AUTH_PASSWORD='process-password' BROWSER_TOKEN='process-token' SCRIPT_ROOT="$fallback_root" bash -c 'set -- help; source "$SCRIPT_ROOT/maintain.sh" >/dev/null; printf "%s,%s" "$(secret_from_env DASHBOARD_AUTH_PASSWORD)" "$(secret_from_env BROWSER_TOKEN)"')"
[[ "$rotation_inputs" == 'process-password,process-token' ]]
for script in install.sh maintain.sh doctor.sh; do
  grep -Fq 'DEFAULT_ENV_FILE="$ROOT_DIR/current_config/hermes.env"' "$fallback_root/$script"
done
grep -Fq 'chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace' "$ROOT_DIR/maintain.sh"
! grep -Fq 'chown -R 1000:1000' "$ROOT_DIR/maintain.sh"
grep -Fq 'find /opt/data /workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} +' "$ROOT_DIR/maintain.sh"
! grep -Fq -- '--from-literal' "$ROOT_DIR/maintain.sh"
grep -Fq 'from-file=token=' "$ROOT_DIR/maintain.sh"
grep -Fq 'chmod 600 "$out"' "$ROOT_DIR/maintain.sh"
grep -Fq 'chmod 600 "$checksum"' "$ROOT_DIR/maintain.sh"
grep -Fq 'umask 077' "$ROOT_DIR/maintain.sh"
grep -Fq 'trap '\''rm -rf -- "$tmpdir"'\'' ERR' "$ROOT_DIR/maintain.sh"
grep -Fq 'trap '\''rm -rf -- "$dash_tmpdir"'\'' ERR' "$ROOT_DIR/install.sh"
grep -Fq 'trap '\''rm -rf -- "$secret_tmpdir"'\'' ERR' "$ROOT_DIR/install.sh"
grep -Fq 'trap backup_on_exit EXIT' "$ROOT_DIR/maintain.sh"
grep -Fq 'parse_env_file' "$ROOT_DIR/maintain.sh"
grep -Fq 'parse_env_file' "$ROOT_DIR/doctor.sh"
grep -Fq 'reject_control_chars' "$ROOT_DIR/scripts/render_template.py"
grep -Fq 'require_pattern' "$ROOT_DIR/scripts/render_template.py"
! grep -Fq 'source "$ENV_FILE"' "$ROOT_DIR/install.sh"
! grep -Fq 'source "$ENV_FILE"' "$ROOT_DIR/maintain.sh"
! grep -Fq 'source "$ENV_FILE"' "$ROOT_DIR/doctor.sh"

grep -Fq 'trap restore_on_exit EXIT' "$ROOT_DIR/maintain.sh"
grep -Fq 'original_replicas' "$ROOT_DIR/maintain.sh"
grep -Fq 'replicas="${original_replicas[$d]}"' "$ROOT_DIR/maintain.sh"
touch "$fallback_root/hermes.env"
resolved_env="$(HERMES_INSTALL_LIB_ONLY=true bash -c 'source "$1/install.sh"; printf "%s" "$ENV_FILE"' _ "$fallback_root")"
[[ "$resolved_env" == "$fallback_root/hermes.env" ]]
touch "$fallback_root/explicit.env"
resolved_env="$(ENV_FILE="$fallback_root/explicit.env" HERMES_INSTALL_LIB_ONLY=true bash -c 'source "$1/install.sh"; printf "%s" "$ENV_FILE"' _ "$fallback_root")"
[[ "$resolved_env" == "$fallback_root/explicit.env" ]]

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
printf '\n\n\n\n\n\n\nn\nn\nn\ny\n13.4.0\ny\n' | \
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

reuse_output="$TMP_DIR/reuse-output"
printf 'y\n' | "$ROOT_DIR/configure.sh" --no-install --config-dir "$config_one" --answers-file "$answers_one" > "$reuse_output"
grep -Fqx "Rebuilding current_config from $answers_one" "$reuse_output"

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
printf '\n\nopenrouter\nopenai/gpt-5.6\n\n\n\ny\ny\ny\nchat.example.com\nadmin.example.com\noperator\n\nn\nn\nn\n' | \
  "$ROOT_DIR/configure.sh" --no-install --config-dir "$config_two" --answers-file "$answers_two" >/dev/null
# shellcheck disable=SC1090
source "$config_two/hermes.env"
[[ "$HERMES_DASHBOARD_ENABLED" == true ]]
[[ "$HERMES_WEBUI_ENABLED" == true ]]
[[ "$HERMES_BROWSER_ENABLED" == true ]]
[[ "$WEBUI_HOST" == chat.example.com ]]
[[ "$DASHBOARD_HOST" == admin.example.com ]]
[[ "$DASHBOARD_AUTH_USER" == operator ]]
DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD:-}"
[[ -z "$DASHBOARD_AUTH_PASSWORD" ]]
[[ "$HERMES_ANSIBLE_SETUP" == false ]]
[[ "$HERMES_SSH_SETUP" == false ]]
[[ "$HERMES_BOOTSTRAP_MODE" == missing ]]
[[ "$MODEL_PROVIDER" == openrouter ]]
[[ "$MODEL_NAME" == openai/gpt-5.6 ]]
grep -qx 'provider: openrouter' "$config_two/bootstrap/config.yaml"
grep -qx 'model: openai/gpt-5.6' "$config_two/bootstrap/config.yaml"
(
  # shellcheck disable=SC1090
  source "$config_two/hermes.env"
  unset DASHBOARD_AUTH_PASSWORD API_SERVER_KEY BROWSER_TOKEN
  export HERMES_INSTALL_LIB_ONLY=true
  # shellcheck disable=SC1090
  source "$ROOT_DIR/install.sh"
  prepare_paths
  prepare_defaults
  DASHBOARD_AUTH_PASSWORD='test-dashboard-password'
  API_SERVER_KEY='test-api-key-long-enough'
  BROWSER_TOKEN='test-browser-token'
  resolve_runtime_credentials
  [[ ! -e "$config_two/artifacts/generated-credentials.txt" ]]
)

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
documents = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
resources = {(d.get('kind'), d.get('metadata', {}).get('name')) for d in documents}
assert ('Deployment', 'hermes-agent') in resources
for name in ('hermes-dashboard', 'hermes-webui', 'hermes-browser'):
    assert ('Deployment', name) not in resources
    assert ('Service', name) not in resources
PY

rendered_all="$TMP_DIR/all-components.yaml"
export HERMES_DASHBOARD_ENABLED=true HERMES_WEBUI_ENABLED=true HERMES_BROWSER_ENABLED=true
export WEBUI_HOST=webui.example.com DASHBOARD_HOST=dashboard.example.com
python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$rendered_all"
python3 - "$rendered_all" <<'PY'
import sys, yaml
for document in yaml.safe_load_all(open(sys.argv[1])):
    if document and document.get('kind') == 'Deployment' and document.get('metadata', {}).get('name') == 'hermes-webui':
        env = {item['name']: item.get('value') for item in document['spec']['template']['spec']['containers'][0]['env']}
        assert env['HERMES_NIX_BUILD'] == '1'
        assert document['spec']['template']['spec']['automountServiceAccountToken'] is False
        assert document['spec']['template']['spec']['securityContext']['seccompProfile']['type'] == 'RuntimeDefault'
        assert document['spec']['template']['spec']['containers'][0]['securityContext']['allowPrivilegeEscalation'] is False
        break
else:
    raise AssertionError('hermes-webui Deployment missing')

for document in yaml.safe_load_all(open(sys.argv[1])):
    if not document or document.get('kind') != 'Deployment':
        continue
    pod = document['spec']['template']['spec']
    assert pod['automountServiceAccountToken'] is False
    assert pod['securityContext']['seccompProfile']['type'] == 'RuntimeDefault'
    if document['metadata']['name'] == 'hermes-browser':
        container = pod['containers'][0]
        assert container['securityContext']['runAsUser'] == 999
        assert container['securityContext']['runAsGroup'] == 999
        assert container['securityContext']['runAsNonRoot'] is True
        assert container['securityContext']['allowPrivilegeEscalation'] is False
        assert container['securityContext']['capabilities']['drop'] == ['ALL']
    elif document['metadata']['name'] in ('hermes-agent', 'hermes-dashboard'):
        assert pod['containers'][0]['securityContext']['allowPrivilegeEscalation'] is False
PY

printf 'configure and component tests passed\n'
