#!/usr/bin/env bash
# Purpose: Validate one persistent, automatically selected SSH identity on fresh setups.
# Scope: Exercise the rendered init-job SSH block and account-home mounts without a cluster.
# Requirements: Bash, Python 3 with PyYAML, OpenSSH client/keygen, and repository scripts.
# Usage: ./tests/ssh-identity.sh
# Exit status: 0 means first-run, repeat-run, and manifest SSH contracts passed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-ssh-identity-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

for command_name in ssh ssh-keygen; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

(
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/examples/hermes.env.example"
  set +a
  export HERMES_INSTALL_LIB_ONLY=true
  # shellcheck disable=SC1091
  source "$ROOT_DIR/install.sh"
  export HERMES_DASHBOARD_ENABLED=true
  export HERMES_WEBUI_ENABLED=true
  export HERMES_BROWSER_ENABLED=false
  export HERMES_BOOTSTRAP_MODE=disabled
  export HERMES_ADDON_REQUIREMENTS=
  export HERMES_SSH_SETUP=true
  export HERMES_SSH_GENERATE_KEY=true
  export HERMES_RENDER_DIR="$TMP_DIR/render"
  prepare_paths
  prepare_defaults
  mkdir -p "$RENDER_DIR"
  python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$MANIFEST_OUT"
  HERMES_SSH_SETUP=false HERMES_SSH_GENERATE_KEY=false \
    python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$TMP_DIR/ssh-disabled.yaml"
)

manifest="$TMP_DIR/render/hermes.yaml"
ssh_block="$TMP_DIR/ssh-init.sh"
python3 - "$manifest" "$TMP_DIR/ssh-disabled.yaml" "$ssh_block" "$TMP_DIR/ssh-disabled-init.sh" <<'PY'
from pathlib import Path
import sys
import yaml

manifest_path, disabled_manifest_path, block_path, disabled_block_path = map(Path, sys.argv[1:])
documents = [doc for doc in yaml.safe_load_all(manifest_path.read_text()) if doc]
by_resource = {(doc["kind"], doc["metadata"]["name"]): doc for doc in documents}

for deployment_name in ("hermes-agent", "hermes-dashboard", "hermes-webui"):
    deployment = by_resource[("Deployment", deployment_name)]
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    env = {item["name"]: item.get("value") for item in container.get("env", [])}
    assert env["HOME"] == "/opt/data", (deployment_name, env.get("HOME"))
    assert env["PATH"].split(":", 1)[0] == "/opt/data/hermes-managed/bin", (
        deployment_name,
        env.get("PATH"),
    )
    mounts = container.get("volumeMounts", [])
    assert not any(mount.get("subPath") == ".ssh" for mount in mounts), deployment_name

disabled_documents = [doc for doc in yaml.safe_load_all(disabled_manifest_path.read_text()) if doc]
for deployment in (doc for doc in disabled_documents if doc.get("kind") == "Deployment"):
    if deployment["metadata"]["name"] == "hermes-browser":
        continue
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    mounts = container.get("volumeMounts", [])
    assert not any(mount.get("subPath") == ".ssh" for mount in mounts), deployment["metadata"]["name"]

job = by_resource[("Job", "hermes-init-config")]
script = job["spec"]["template"]["spec"]["containers"][0]["args"][0]
start = script.index('if [ "true" != "false"')
end = script.index('if [ "false" = "true"', start)
block = script[start:end]
for required in (
    "# BEGIN kube.hermes_setup SSH identity",
    "IdentityFile /opt/data/.ssh/id_ed25519",
    "IdentitiesOnly yes",
    "/opt/data/hermes-managed/bin/ssh",
):
    assert required in block, required
block_path.write_text("set -eu\n" + block.replace("/opt/data", "__TEST_HOME__"))

disabled_job = next(
    doc
    for doc in disabled_documents
    if doc.get("kind") == "Job" and doc["metadata"]["name"] == "hermes-init-config"
)
disabled_script = disabled_job["spec"]["template"]["spec"]["containers"][0]["args"][0]
disabled_start = disabled_script.index('if [ "false" != "false"')
disabled_end = disabled_script.index('if [ "false" = "true"', disabled_start)
disabled_block_path.write_text(
    "set -eu\n" + disabled_script[disabled_start:disabled_end].replace("/opt/data", "__TEST_HOME__")
)
PY

home="$TMP_DIR/home"
mkdir -p "$home"
sed "s#__TEST_HOME__#$home#g" "$ssh_block" > "$TMP_DIR/run-ssh-init.sh"
chmod 700 "$TMP_DIR/run-ssh-init.sh"

disabled_home="$TMP_DIR/disabled-home"
mkdir -p "$disabled_home"
sed "s#__TEST_HOME__#$disabled_home#g" "$TMP_DIR/ssh-disabled-init.sh" > "$TMP_DIR/run-ssh-disabled-init.sh"
chmod 700 "$TMP_DIR/run-ssh-disabled-init.sh"
"$TMP_DIR/run-ssh-disabled-init.sh"
[[ ! -e "$disabled_home/.ssh" ]]
[[ ! -e "$disabled_home/hermes-managed/bin/ssh" ]]
mkdir -p "$disabled_home/.ssh" "$disabled_home/hermes-managed/bin"
printf '%s\n' preserved-key > "$disabled_home/.ssh/id_ed25519"
printf '%s\n' stale-wrapper > "$disabled_home/hermes-managed/bin/ssh"
"$TMP_DIR/run-ssh-disabled-init.sh"
[[ -f "$disabled_home/.ssh/id_ed25519" ]]
[[ ! -e "$disabled_home/hermes-managed/bin/ssh" ]]

"$TMP_DIR/run-ssh-init.sh"
[[ "$(stat -c %a "$home/.ssh")" == 700 ]]
[[ "$(stat -c %a "$home/.ssh/id_ed25519")" == 600 ]]
[[ "$(stat -c %a "$home/.ssh/id_ed25519.pub")" == 644 ]]
[[ "$(stat -c %a "$home/.ssh/config")" == 600 ]]
[[ "$(stat -c %a "$home/hermes-managed/bin/ssh")" == 755 ]]
[[ "$(find "$home/.ssh" -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' | wc -l)" == 1 ]]

first_fingerprint="$(ssh-keygen -lf "$home/.ssh/id_ed25519.pub" | awk '{print $2}')"
printf '%s\n' 'Host operator.example' '    User preserved-operator' >> "$home/.ssh/config"
"$TMP_DIR/run-ssh-init.sh"
second_fingerprint="$(ssh-keygen -lf "$home/.ssh/id_ed25519.pub" | awk '{print $2}')"
[[ "$first_fingerprint" == "$second_fingerprint" ]]
[[ "$(grep -Fc '# BEGIN kube.hermes_setup SSH identity' "$home/.ssh/config")" == 1 ]]
grep -Fqx '    User preserved-operator' "$home/.ssh/config"

ssh_effective="$(PATH="$home/hermes-managed/bin:$PATH" ssh -G example.invalid 2>/dev/null)"
grep -Fqx "identityfile $home/.ssh/id_ed25519" <<< "$ssh_effective"
grep -Fqx 'identitiesonly yes' <<< "$ssh_effective"

for defaults in "$ROOT_DIR"/examples/bootstrap-profiles/*/defaults.conf; do
  (
    # shellcheck disable=SC1090
    source "$defaults"
    [[ "$HERMES_PROFILE_DEFAULT_SSH_SETUP" == true ]]
  )
done

grep -Fq 'ssh -G example.invalid' "$ROOT_DIR/doctor.sh"
grep -Fq 'private/public fingerprints match' "$ROOT_DIR/doctor.sh"

printf 'SSH identity tests passed: one persistent key, preserved on rerun, selected by ordinary ssh from every runtime PATH\n'
