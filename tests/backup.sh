#!/usr/bin/env bash
# Purpose: Verify encrypted backup helper contracts without a Kubernetes cluster.
# Scope: Test age passphrase delivery through a PTY, password-file permissions, strict
#        restore archive validation, Kubernetes snapshot normalization, full-restore dry-run,
#        K3s version mismatch refusal, and explicit --force handling.
# Requirements: Bash, Python 3, tar, sha256sum, and repository scripts.
# Usage: ./tests/backup.sh
# Exit status: 0 means all backup contracts passed; non-zero identifies a failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-backup-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/input"
printf 'payload\n' > "$TMP_DIR/input/plain.txt"
printf 'correct horse battery staple\n' > "$TMP_DIR/password"
chmod 600 "$TMP_DIR/password"

cat > "$TMP_DIR/bin/age" <<'AGE'
#!/usr/bin/env bash
# Fake age for test: reads passphrase from PTY (twice for encrypt, once for decrypt)
if [[ " $* " == *' --passphrase '* ]] && [[ " $* " != *' --decrypt '* ]]; then
  read -r prompt1
  read -r prompt2
  [[ "$prompt1" == "$prompt2" ]]
else
  read -r prompt
fi
[[ "$prompt" == 'correct horse battery staple' ]]
if [[ " $* " == *' --decrypt '* ]]; then
  while (($#)); do
    [[ "$1" == --output ]] && { output="$2"; shift 2; continue; }
    input="$1"
    shift
  done
  cp "$input" "$output" 2>/dev/null || true
fi
echo 'fake age completed'
AGE
chmod 700 "$TMP_DIR/bin/age"
PATH="$TMP_DIR/bin:$PATH" python3 "$ROOT_DIR/scripts/age_passphrase.py" "$TMP_DIR/password" -- age --passphrase "$TMP_DIR/input/plain.txt" > "$TMP_DIR/age.out"
grep -Fq 'fake age completed' "$TMP_DIR/age.out"

if chmod 644 "$TMP_DIR/password"; then
  if PATH="$TMP_DIR/bin:$PATH" python3 "$ROOT_DIR/scripts/age_passphrase.py" "$TMP_DIR/password" -- age --passphrase "$TMP_DIR/input/plain.txt" >/dev/null 2>&1; then
    printf 'insecure password file unexpectedly accepted\n' >&2
    exit 1
  fi
fi
chmod 600 "$TMP_DIR/password"

mkdir -p "$TMP_DIR/archive-root/opt/data" "$TMP_DIR/archive-root/workspace" "$TMP_DIR/archive-root/metadata"
printf ok > "$TMP_DIR/archive-root/opt/data/file"
printf config > "$TMP_DIR/archive-root/metadata/hermes.env"
printf answers > "$TMP_DIR/archive-root/metadata/configuration_answers"
printf info > "$TMP_DIR/archive-root/metadata/backup-info.txt"
mkdir -p "$TMP_DIR/archive-root/metadata/bootstrap/skills"
printf bootstrap > "$TMP_DIR/archive-root/metadata/bootstrap/SOUL.md"
printf skill > "$TMP_DIR/archive-root/metadata/bootstrap/skills/example.md"
tar -czf "$TMP_DIR/good.tgz" -C "$TMP_DIR/archive-root" opt/data workspace metadata
HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1/maintain.sh"; validate_backup_archive "$2"' _ "$ROOT_DIR" "$TMP_DIR/good.tgz"
PATH="$TMP_DIR/bin:$PATH" ./maintain.sh extract "$TMP_DIR/good.tgz" --output-dir "$TMP_DIR/recovery-bootstrap" --component bootstrap --password-file "$TMP_DIR/password"
[[ -f "$TMP_DIR/recovery-bootstrap/bootstrap/SOUL.md" && -f "$TMP_DIR/recovery-bootstrap/bootstrap/skills/example.md" ]]
[[ ! -e "$TMP_DIR/recovery-bootstrap/hermes.env" ]]
PATH="$TMP_DIR/bin:$PATH" ./maintain.sh extract "$TMP_DIR/good.tgz" --output-dir "$TMP_DIR/recovery-config" --component config --password-stdin <<< 'correct horse battery staple'
[[ -f "$TMP_DIR/recovery-config/hermes.env" && -f "$TMP_DIR/recovery-config/configuration_answers" ]]
PATH="$TMP_DIR/bin:$PATH" ./maintain.sh extract "$TMP_DIR/good.tgz" --output-dir "$TMP_DIR/recovery-dry" --full --password-file "$TMP_DIR/password" --dry-run
[[ ! -e "$TMP_DIR/recovery-dry" ]]
mkdir -p "$TMP_DIR/bad-root/outside"
tar -czf "$TMP_DIR/bad.tgz" -C "$TMP_DIR/bad-root" outside
if HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1/maintain.sh"; validate_backup_archive "$2"' _ "$ROOT_DIR" "$TMP_DIR/bad.tgz" >/dev/null 2>&1; then
  printf 'outside archive path unexpectedly accepted\n' >&2
  exit 1
fi
ln -s ../outside "$TMP_DIR/archive-root/opt/data/link"
tar -czf "$TMP_DIR/link.tgz" -C "$TMP_DIR/archive-root" opt/data workspace metadata
if HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1/maintain.sh"; validate_backup_archive "$2"' _ "$ROOT_DIR" "$TMP_DIR/link.tgz" >/dev/null 2>&1; then
  printf 'archive symlink unexpectedly accepted\n' >&2
  exit 1
fi

mkdir -p "$TMP_DIR/raw"
cat > "$TMP_DIR/raw/namespace.json" <<'JSON'
{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"bob","uid":"drop-me"},"status":{"phase":"Active"}}
JSON
for resource in pvc deployment service job ingress networkpolicy serviceaccount middleware; do
  cat > "$TMP_DIR/raw/$resource.json" <<JSON
{"apiVersion":"v1","kind":"${resource^}","metadata":{"name":"hermes-$resource","namespace":"bob","uid":"drop-me","resourceVersion":"drop-me"},"spec":{},"status":{"phase":"drop-me"}}
JSON
done
api_key_b64="$(printf '%s' 'restored-api-key-long-enough' | base64 -w0)"
cat > "$TMP_DIR/raw/secret.json" <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"hermes-dashboard-auth","namespace":"bob","uid":"drop-me"},"data":{"password":"REDACTED-TEST-DATA"}},{"apiVersion":"v1","kind":"Secret","metadata":{"name":"hermes-api-server","namespace":"bob","uid":"drop-me"},"data":{"api-key":"$api_key_b64"}}]}
JSON
cat > "$TMP_DIR/raw/cluster-version.txt" <<'EOF'
v1.31.0+k3s1
EOF
python3 "$ROOT_DIR/scripts/kube_snapshot.py" snapshot "$TMP_DIR/raw" "$TMP_DIR/resources.json" bob
python3 "$ROOT_DIR/scripts/kube_snapshot.py" split "$TMP_DIR/resources.json" "$TMP_DIR/namespace.json" "$TMP_DIR/resources-list.json"
python3 - "$TMP_DIR/resources.json" "$TMP_DIR/resources-list.json" <<'PY'
import json, sys
snapshot = json.load(open(sys.argv[1]))
resources = json.load(open(sys.argv[2]))
assert len(snapshot['items']) == 11
assert resources['items']
assert all('uid' not in item.get('metadata', {}) for item in snapshot['items'])
assert all('status' not in item for item in snapshot['items'])
assert any(item['kind'] == 'Secret' for item in snapshot['items'])
PY

HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_snapshot_api_key "$2"' _ "$ROOT_DIR/maintain.sh" "$TMP_DIR/resources.json"
python3 - "$TMP_DIR/resources.json" "$TMP_DIR" <<'PY'
import base64, copy, json, sys
source, output_dir = sys.argv[1:]
data=json.load(open(source))
secret=next(item for item in data['items'] if item.get('kind')=='Secret' and item.get('metadata',{}).get('name')=='hermes-api-server')

def write(name, value):
    payload=copy.deepcopy(data)
    if name == 'missing':
        payload['items']=[item for item in payload['items'] if not (item.get('kind')=='Secret' and item.get('metadata',{}).get('name')=='hermes-api-server')]
    elif name == 'duplicate':
        payload['items'].append(copy.deepcopy(secret))
    else:
        target=next(item for item in payload['items'] if item.get('kind')=='Secret' and item.get('metadata',{}).get('name')=='hermes-api-server')
        target['data']['api-key']=value
    json.dump(payload,open(f'{output_dir}/resources-invalid-{name}.json','w'))

write('missing', None)
write('duplicate', None)
write('malformed-base64', '%%%')
write('non-ascii', base64.b64encode(b'\xff'*16).decode())
write('short', base64.b64encode(b'short').decode())
write('dotenv-unsafe', base64.b64encode(b'1234567890123456 #suffix').decode())
write('tilde-unsafe', base64.b64encode(b'~1234567890123456').decode())
PY
for invalid_case in missing duplicate malformed-base64 non-ascii short dotenv-unsafe tilde-unsafe; do
  if HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_snapshot_api_key "$2"' _ "$ROOT_DIR/maintain.sh" "$TMP_DIR/resources-invalid-$invalid_case.json" >/dev/null 2>&1; then
    printf 'snapshot validator unexpectedly accepted %s API key case\n' "$invalid_case" >&2
    exit 1
  fi
done
mkdir -p "$TMP_DIR/snapshot-fail-bin" "$TMP_DIR/snapshot-fail-raw"
cat > "$TMP_DIR/snapshot-fail-bin/kubectl" <<'KUBECTL_FAIL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == version ]]; then
  printf '{"serverVersion":{"gitVersion":"v1.31.0+k3s1"}}\n'
elif [[ "$1" == get && "$2" == namespace ]]; then
  printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"bob"}}\n'
elif [[ " $* " == *' get secret '* ]]; then
  exit 1
elif [[ "$1" == -n && "$3" == get ]]; then
  printf '{"apiVersion":"v1","kind":"List","items":[]}\n'
fi
KUBECTL_FAIL
chmod 700 "$TMP_DIR/snapshot-fail-bin/kubectl"
if PATH="$TMP_DIR/snapshot-fail-bin:$PATH" HERMES_NAMESPACE=bob HERMES_MAINTAIN_LIB_ONLY=true \
  bash -c 'source "$1"; snapshot_kubernetes_state "$2" "$3" "$4"' _ "$ROOT_DIR/maintain.sh" \
  "$TMP_DIR/snapshot-fail-raw" "$TMP_DIR/snapshot-fail.json" "$TMP_DIR/snapshot-fail-version.json" >/dev/null 2>&1; then
  printf 'snapshot unexpectedly succeeded without Secret read access\n' >&2
  exit 1
fi
[[ ! -e "$TMP_DIR/snapshot-fail.json" ]]
python3 - "$ROOT_DIR/maintain.sh" <<'PY'
from pathlib import Path
import sys
body=Path(sys.argv[1]).read_text().split('restore_kubernetes_snapshot() {',1)[1].split('\n}',1)[0]
assert body.index('validate_snapshot_api_key') < body.index('kubectl apply -f "$namespace_json"')
assert body.index('validate_snapshot_api_key') < body.index('kubectl apply -f "$resources_json"')
PY

python3 - "$TMP_DIR/resources.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
for name in ('hermes-agent', 'hermes-dashboard', 'hermes-webui'):
    data['items'].append({
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {'name': name, 'namespace': 'bob'},
        'spec': {'replicas': 1, 'template': {'metadata': {'annotations': {
            'kube-hermes-setup.example.com/api-key-revision': 'stale-backup-revision'
        }}}},
    })
json.dump(data, open(path, 'w'))
PY

rm -f "$TMP_DIR/archive-root/opt/data/link"
mkdir -p "$TMP_DIR/full-root/metadata/kubernetes"
cp -a "$TMP_DIR/archive-root/." "$TMP_DIR/full-root/"
cp "$TMP_DIR/resources.json" "$TMP_DIR/full-root/metadata/kubernetes/resources.json"
printf 'v1.31.0+k3s1\n' > "$TMP_DIR/full-root/metadata/kubernetes/cluster-version.txt"
tar -czf "$TMP_DIR/full.tgz" -C "$TMP_DIR/full-root" opt/data workspace metadata
cat > "$TMP_DIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${FAKE_KUBECTL_CALLS:-}" ]] || printf '%s\n' "$*" >> "$FAKE_KUBECTL_CALLS"
if [[ "$1" == version ]]; then
  printf '{"serverVersion":{"gitVersion":"%s"}}\n' "${FAKE_K3S_VERSION:-v1.31.0+k3s1}"
elif [[ "$1" == get && "$2" == namespace ]]; then
  printf 'namespace/bob\n'
elif [[ " $* " == *' get secret hermes-api-server '* && " $* " == *"jsonpath={.data['api-key']}"* ]]; then
  printf '%s' 'restored-api-key-long-enough' | base64
elif [[ " $* " == *' get secret hermes-api-server '* && " $* " == *'jsonpath={.metadata.resourceVersion}'* ]]; then
  printf 'restored-resource-version'
elif [[ " $* " == *' get deploy '* && " $* " == *'jsonpath={.spec.replicas}'* ]]; then
  printf '1'
elif [[ " $* " == *' exec -i hermes-restore '* ]]; then
  cat > "${FAKE_RESTORED_KEY_INPUT:?}"
fi
KUBECTL
chmod 700 "$TMP_DIR/bin/kubectl"
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.31.0+k3s1 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --password-file "$TMP_DIR/password"
if PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.32.0+k3s1 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --password-file "$TMP_DIR/password" > "$TMP_DIR/mismatch.out" 2>&1; then
  printf 'K3s version mismatch unexpectedly accepted\n' >&2
  exit 1
fi
grep -Fq 'K3s version mismatch' "$TMP_DIR/mismatch.out"
if PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.31.0 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --force --password-file "$TMP_DIR/password" > "$TMP_DIR/non-k3s.out" 2>&1; then
  :
else
  printf 'forced non-K3s restore unexpectedly refused\n' >&2
  exit 1
fi
grep -Fq 'continuing because --force' "$TMP_DIR/non-k3s.out"
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=other FAKE_K3S_VERSION=v1.31.0+k3s1 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --force --password-file "$TMP_DIR/password" > "$TMP_DIR/namespace-force.out" 2>&1
grep -Fq 'Forcing restore into backup Namespace: backup=bob configured=other' "$TMP_DIR/namespace-force.out"
rm -f "$TMP_DIR/full-root/metadata/kubernetes/cluster-version.txt"
tar -czf "$TMP_DIR/no-version.tgz" -C "$TMP_DIR/full-root" opt/data workspace metadata
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.31.0+k3s1 ./maintain.sh restore "$TMP_DIR/no-version.tgz" --full --dry-run --force --password-file "$TMP_DIR/password" > "$TMP_DIR/no-version.out" 2>&1
grep -Fq 'no K3s version metadata' "$TMP_DIR/no-version.out"
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.32.0+k3s1 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --force --password-file "$TMP_DIR/password" >/dev/null

: > "$TMP_DIR/kubectl.calls"
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.31.0+k3s1 FAKE_KUBECTL_CALLS="$TMP_DIR/kubectl.calls" FAKE_RESTORED_KEY_INPUT="$TMP_DIR/restored-key.input" \
  ./maintain.sh restore "$TMP_DIR/full.tgz" --full --password-file "$TMP_DIR/password" >/dev/null
for deployment in hermes-agent hermes-dashboard hermes-webui; do
  grep -Fq "patch deployment $deployment --type=merge" "$TMP_DIR/kubectl.calls"
done
grep -Fq 'restored-resource-version' "$TMP_DIR/kubectl.calls"
grep -Fq 'get secret hermes-api-server' "$TMP_DIR/kubectl.calls"
grep -Fq 'exec -i hermes-restore' "$TMP_DIR/kubectl.calls"
grep -qx 'restored-api-key-long-enough' "$TMP_DIR/restored-key.input"
python3 - "$ROOT_DIR/maintain.sh" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
body = text.split('restore() {', 1)[1].split('\nprompt_secret() {', 1)[0]
prepare = body.index('prepare_restored_api_key_sync')
copy = body.index('kubectl -n "$HERMES_NAMESPACE" cp "$plain"')
destructive = body.index('find /opt/data /workspace')
sync = body.index('sync_restored_api_key')
scale_down = body.index('log "Scaling down write-heavy deployments"')
scale_up = body.index('log "Scaling deployments up"')
cleanup_enabled_before = body.index('restore_scale_up_on_cleanup=true', 0, scale_down)
cleanup_disabled = body.index('restore_scale_up_on_cleanup=false', copy, destructive)
cleanup_enabled_after = body.index('restore_scale_up_on_cleanup=true', sync, scale_up)
assert prepare < copy < cleanup_disabled < destructive < sync < cleanup_enabled_after < scale_up
assert cleanup_enabled_before < scale_down
assert 'if [[ "$restore_scale_up_on_cleanup" == true ]]' in body
PY

sync_script="$(HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; restored_api_key_sync_script' _ "$ROOT_DIR/maintain.sh")"
grep -Fq 'mktemp "${env_file}.XXXXXX"' <<<"$sync_script"
valid_encoded="$(printf '%s' 'restored-api-key-long-enough' | base64 -w0)"
HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_encoded_api_key "$2"' _ "$ROOT_DIR/maintain.sh" "$valid_encoded"
punctuation_encoded="$(printf '%s' '1234567890123456._:/+=@%-' | base64 -w0)"
HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_encoded_api_key "$2"' _ "$ROOT_DIR/maintain.sh" "$punctuation_encoded"
python3 - "$TMP_DIR" <<'PY'
import base64, pathlib, sys
root=pathlib.Path(sys.argv[1])
cases={
    'nul': b'restored-api-key-long-enough\0',
    'short': b'short',
    'non-ascii': b'\xff'*16,
    'unsafe-ascii': b'1234567890123456 #suffix',
}
for name,value in cases.items():
    (root/f'encoded-invalid-{name}').write_text(base64.b64encode(value).decode())
(root/'encoded-invalid-malformed').write_text('%%%')
PY
for invalid_case in nul short non-ascii unsafe-ascii malformed; do
  if HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_encoded_api_key "$2"' _ \
    "$ROOT_DIR/maintain.sh" "$(<"$TMP_DIR/encoded-invalid-$invalid_case")"; then
    printf 'encoded-key validator unexpectedly accepted %s case\n' "$invalid_case" >&2
    exit 1
  fi
done
sync_env="$TMP_DIR/restored-runtime.env"
printf '%s\n' 'UNRELATED_SETTING=keep-me' 'API_SERVER_KEY=stale-one' 'API_SERVER_KEY=stale-two' > "$sync_env"
cp "$sync_env" "$TMP_DIR/validate-only.before"
printf '%s' 'restored-api-key-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env" validate-only
cmp -s "$sync_env" "$TMP_DIR/validate-only.before"
printf '%s' 'restored-api-key-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"
grep -qx 'UNRELATED_SETTING=keep-me' "$sync_env"
grep -qx 'API_SERVER_KEY=restored-api-key-long-enough' "$sync_env"
[[ "$(grep -c '^API_SERVER_KEY=' "$sync_env")" == 1 ]]
[[ "$(stat -c %a "$sync_env")" == 600 ]]
cp "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf 'bad\rkey-value-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted carriage return\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf 'bad\nkey-value-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted newline\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf 'short' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted weak API key\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf '1234567890123456 #suffix' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted dotenv-unsafe API key\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf 'bad-key-value-long-enough\n' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted trailing newline\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"

printf 'encrypted backup helper tests passed\n'
