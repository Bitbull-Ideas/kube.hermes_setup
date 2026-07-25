#!/usr/bin/env bash
# Purpose: Verify encrypted backup helper contracts without a Kubernetes cluster.
# Scope: Test age passphrase delivery through a PTY, password-file permissions, and
#        restore archive path/link validation using local temporary fixtures.
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
set -euo pipefail
printf 'Enter passphrase: ' >&2
read -r prompt
[[ "$prompt" == 'correct horse battery staple' ]]
if [[ " $* " == *' --decrypt '* ]]; then
  while (($#)); do
    [[ "$1" == --output ]] && { output="$2"; shift 2; continue; }
    input="$1"
    shift
done
  cp "$input" "$output"
fi
printf 'fake age completed\n'
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

printf 'encrypted backup helper tests passed\n'
