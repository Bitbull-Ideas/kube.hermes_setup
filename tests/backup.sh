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
cat > "$TMP_DIR/raw/secret.json" <<'JSON'
{"apiVersion":"v1","kind":"Secret","metadata":{"name":"hermes-dashboard-auth","namespace":"bob","uid":"drop-me"},"data":{"password":"REDACTED-TEST-DATA"}}
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
assert len(snapshot['items']) == 10
assert resources['items']
assert all('uid' not in item.get('metadata', {}) for item in snapshot['items'])
assert all('status' not in item for item in snapshot['items'])
assert any(item['kind'] == 'Secret' for item in snapshot['items'])
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
if [[ "$1" == version ]]; then
  printf '{"serverVersion":{"gitVersion":"%s"}}\n' "${FAKE_K3S_VERSION:-v1.31.0+k3s1}"
elif [[ "$1" == get && "$2" == namespace ]]; then
  printf 'namespace/bob\n'
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

printf 'encrypted backup helper tests passed\n'
