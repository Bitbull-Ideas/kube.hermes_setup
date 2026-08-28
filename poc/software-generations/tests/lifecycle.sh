#!/usr/bin/env bash
# Verify immutable Python/Node generations, exact reconciliation, rollback, and failure safety.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SOFTWARE_ROOT:?SOFTWARE_ROOT must be an externally managed fresh directory}"
: "${TEST_TMP:?TEST_TMP must be a separate externally managed fresh directory}"
REQUIREMENTS_A="${REQUIREMENTS_A:-$ROOT_DIR/requirements-a.lock}"
REQUIREMENTS_B="${REQUIREMENTS_B:-$ROOT_DIR/requirements-b.lock}"
REQUIREMENTS_BAD="${REQUIREMENTS_BAD:-$ROOT_DIR/requirements-bad.lock}"
PYTHON_BIN="${PYTHON_BIN:-/opt/data/uv/python/cpython-3.13-linux-x86_64-gnu/bin/python3}"
NODE_SRC="${NODE_SRC:-/opt/data/node/bin/node}"
NPM_SRC="${NPM_SRC:-/opt/data/node/lib/node_modules/npm}"
NODE_SRC_ORIGINAL="$NODE_SRC"
NPM_SRC_ORIGINAL="$NPM_SRC"
TEST_SOURCE_DIGEST="${TEST_SOURCE_DIGEST:-sha256:1111111111111111111111111111111111111111111111111111111111111111}"
PY_RECONCILE="$ROOT_DIR/python/reconcile.sh"
NODE_RECONCILE="$ROOT_DIR/node/reconcile.sh"
ROLLBACK="$ROOT_DIR/rollback-generation.sh"
mkdir -p "$SOFTWARE_ROOT"
mkdir -p "$TEST_TMP"
readarray -t canonical_paths < <(python3 - "$SOFTWARE_ROOT" "$TEST_TMP" <<'PY'
import pathlib,sys
software_root=pathlib.Path(sys.argv[1]).resolve(strict=True)
test_tmp=pathlib.Path(sys.argv[2]).resolve(strict=True)
assert str(software_root) != '/' and str(test_tmp) != '/'
assert software_root != test_tmp
assert software_root not in test_tmp.parents
assert test_tmp not in software_root.parents
print(software_root)
print(test_tmp)
PY
)
SOFTWARE_ROOT="${canonical_paths[0]}"
TEST_TMP="${canonical_paths[1]}"
for script in "$PY_RECONCILE" "$NODE_RECONCILE" "$ROLLBACK"; do
  [[ -x "$script" ]] || { printf 'missing executable: %s\n' "$script" >&2; exit 1; }
done

link_target() { readlink "$1"; }
generation_count() { find "$1/generations" -mindepth 1 -maxdepth 1 -type d | wc -l; }
assert_clean_component() {
  local component="$1"
  ! find "$component/generations" -mindepth 1 -maxdepth 1 -type d ! -exec test -f '{}/.complete' ';' -print -quit | grep -q .
  ! find "$component/staging" -mindepth 1 -print -quit | grep -q .
}
assert_python_inventory() {
  local python="$1" expected="$2"
  local actual
  actual="$($python - <<'PY'
import importlib.metadata as md
ignored={"pip","setuptools","wheel"}
print(",".join(sorted({(d.metadata.get("Name") or d.name).lower().replace("_","-") for d in md.distributions()}-ignored)))
PY
)"
  [[ "$actual" == "$expected" ]]
}
assert_metadata_roots() {
  local file="$1" component="$2" hash="$3" digest="$4"
  python3 - "$file" "$component" "$SOFTWARE_ROOT" "$hash" "$digest" <<'PY'
import json,pathlib,sys
file,component,root,generation,digest=sys.argv[1:]
data=json.loads(pathlib.Path(file).read_text())
component_root=str(pathlib.Path(root)/component)
generation_path=str(pathlib.Path(component_root)/"generations"/generation)
assert data["component"]==component
assert data["software_root"]==root
assert data["component_root"]==component_root
assert data["generation_path"]==generation_path
assert data["generation_hash"]==generation
assert data["source_digest"]==digest
PY
}
atomic_link() {
  local target="$1"
  local link="$2"
  local tmp="${link}.test.$$"
  rm -f "$tmp"
  ln -s "$target" "$tmp"
  mv -Tf "$tmp" "$link"
}
assert_rollback_rejects() {
  local component="$1"
  local bad_current="$2"
  local bad_previous="$3"
  local before_current before_previous
  atomic_link "$bad_current" "$SOFTWARE_ROOT/$component/current"
  atomic_link "$bad_previous" "$SOFTWARE_ROOT/$component/previous"
  before_current="$(readlink "$SOFTWARE_ROOT/$component/current")"
  before_previous="$(readlink "$SOFTWARE_ROOT/$component/previous")"
  if "$ROLLBACK" "$component" >/dev/null 2>&1; then
    printf 'rollback accepted malformed links: %s %s\n' "$bad_current" "$bad_previous" >&2
    exit 1
  fi
  [[ "$(readlink "$SOFTWARE_ROOT/$component/current")" == "$before_current" ]]
  [[ "$(readlink "$SOFTWARE_ROOT/$component/previous")" == "$before_previous" ]]
}

# Python A: exact locked inventory, metadata, reuse, and no previous link.
export SOFTWARE_ROOT PYTHON_BIN BUILDER_IMAGE_DIGEST="$TEST_SOURCE_DIGEST" LOCKFILE="$REQUIREMENTS_A"
py_a="$($PY_RECONCILE)"
[[ "$py_a" =~ ^[0-9a-f]{64}$ ]]
[[ "$(wc -l <<<"$py_a")" == 1 ]]
[[ "$(link_target "$SOFTWARE_ROOT/python/current")" == "generations/$py_a" ]]
[[ ! -e "$SOFTWARE_ROOT/python/previous" ]]
assert_python_inventory "$SOFTWARE_ROOT/python/current/bin/python" 'pyfiglet,six'
"$SOFTWARE_ROOT/python/current/bin/python" -c 'import pyfiglet,six; assert six.__version__=="1.17.0"; assert pyfiglet.figlet_format("A")'
"$SOFTWARE_ROOT/python/current/bin/pyfiglet" A >/dev/null
assert_metadata_roots "$SOFTWARE_ROOT/python/generations/$py_a/metadata.json" python "$py_a" "$TEST_SOURCE_DIGEST"
py_count="$(generation_count "$SOFTWARE_ROOT/python")"
[[ "$($PY_RECONCILE)" == "$py_a" ]]
[[ "$(generation_count "$SOFTWARE_ROOT/python")" == "$py_count" ]]
assert_clean_component "$SOFTWARE_ROOT/python"

# Python B removes six exactly; a bad lock cannot move links or add generations.
export BUILDER_IMAGE_DIGEST="$TEST_SOURCE_DIGEST" LOCKFILE="$REQUIREMENTS_B"
py_b="$($PY_RECONCILE)"
[[ "$py_b" != "$py_a" ]]
[[ "$py_b" =~ ^[0-9a-f]{64}$ && "$(wc -l <<<"$py_b")" == 1 ]]
[[ "$(link_target "$SOFTWARE_ROOT/python/current")" == "generations/$py_b" ]]
[[ "$(link_target "$SOFTWARE_ROOT/python/previous")" == "generations/$py_a" ]]
assert_python_inventory "$SOFTWARE_ROOT/python/current/bin/python" pyfiglet
if "$SOFTWARE_ROOT/python/current/bin/python" -c 'import six' 2>/dev/null; then exit 1; fi
before_current="$(link_target "$SOFTWARE_ROOT/python/current")"; before_previous="$(link_target "$SOFTWARE_ROOT/python/previous")"; before_count="$(generation_count "$SOFTWARE_ROOT/python")"
export BUILDER_IMAGE_DIGEST="$TEST_SOURCE_DIGEST" LOCKFILE="$REQUIREMENTS_BAD"
if "$PY_RECONCILE" >"$TEST_TMP/python-bad.log" 2>&1; then exit 1; fi
[[ "$(link_target "$SOFTWARE_ROOT/python/current")" == "$before_current" ]]
[[ "$(link_target "$SOFTWARE_ROOT/python/previous")" == "$before_previous" ]]
[[ "$(generation_count "$SOFTWARE_ROOT/python")" == "$before_count" ]]
assert_clean_component "$SOFTWARE_ROOT/python"

# Atomic rollback exchanges A/B, then two concurrent unchanged A runs converge.
"$ROLLBACK" python >/dev/null
[[ "$(link_target "$SOFTWARE_ROOT/python/current")" == "generations/$py_a" ]]
[[ "$(link_target "$SOFTWARE_ROOT/python/previous")" == "generations/$py_b" ]]
assert_python_inventory "$SOFTWARE_ROOT/python/current/bin/python" 'pyfiglet,six'
export BUILDER_IMAGE_DIGEST="$TEST_SOURCE_DIGEST" LOCKFILE="$REQUIREMENTS_A"
"$PY_RECONCILE" >"$TEST_TMP/py-concurrent-1" & p1=$!
"$PY_RECONCILE" >"$TEST_TMP/py-concurrent-2" & p2=$!
wait "$p1"; wait "$p2"
[[ "$(cat "$TEST_TMP/py-concurrent-1")" == "$py_a" ]]
[[ "$(cat "$TEST_TMP/py-concurrent-2")" == "$py_a" ]]
[[ "$(generation_count "$SOFTWARE_ROOT/python")" == 2 ]]
assert_clean_component "$SOFTWARE_ROOT/python"

# Existing complete Python generations are revalidated and corruption fails closed.
python_meta="$SOFTWARE_ROOT/python/generations/$py_a/metadata.json"; cp "$python_meta" "$TEST_TMP/python-meta.good"
printf '{}\n' >"$python_meta"; py_cur="$(link_target "$SOFTWARE_ROOT/python/current")"; py_prev="$(link_target "$SOFTWARE_ROOT/python/previous")"; py_count="$(generation_count "$SOFTWARE_ROOT/python")"
if "$PY_RECONCILE" >/dev/null 2>&1; then exit 1; fi
[[ "$(link_target "$SOFTWARE_ROOT/python/current")" == "$py_cur" && "$(link_target "$SOFTWARE_ROOT/python/previous")" == "$py_prev" && "$(generation_count "$SOFTWARE_ROOT/python")" == "$py_count" ]]
mv "$TEST_TMP/python-meta.good" "$python_meta"; assert_clean_component "$SOFTWARE_ROOT/python"

# Malformed and incomplete rollback targets fail without changing either link.
good_a="generations/$py_a"; good_b="generations/$py_b"
assert_rollback_rejects python /tmp/absolute "$good_b"
assert_rollback_rejects python "../$good_a" "$good_b"
assert_rollback_rejects python generations/not-a-hash "$good_b"
assert_rollback_rejects python "$good_a/extra" "$good_b"
incomplete="$(printf incomplete|sha256sum|cut -d' ' -f1)"; mkdir "$SOFTWARE_ROOT/python/generations/$incomplete"
assert_rollback_rejects python "$good_a" "generations/$incomplete"
rm -rf "$SOFTWARE_ROOT/python/generations/$incomplete"
atomic_link "$good_a" "$SOFTWARE_ROOT/python/current"; atomic_link "$good_b" "$SOFTWARE_ROOT/python/previous"

# Node A: executable payload/wrappers, inherited loader preservation, hostile PATH, reuse, concurrency.
export NODE_SRC NPM_SRC SOURCE_IMAGE_DIGEST="$TEST_SOURCE_DIGEST"; unset LDD_BIN || true
node_a="$($NODE_RECONCILE)"
[[ "$node_a" =~ ^[0-9a-f]{64}$ ]]
[[ "$(wc -l <<<"$node_a")" == 1 ]]
node_current="$SOFTWARE_ROOT/node/current"; node_lib="$SOFTWARE_ROOT/node/generations/$node_a/lib"
[[ "$(link_target "$node_current")" == "generations/$node_a" ]]
assert_metadata_roots "$SOFTWARE_ROOT/node/generations/$node_a/metadata.json" node "$node_a" "$TEST_SOURCE_DIGEST"
"$node_current/bin/node" --version >/dev/null; "$node_current/bin/npm" --version >/dev/null; "$node_current/bin/npx" --version >/dev/null
unset LD_LIBRARY_PATH || true
[[ "$("$node_current/bin/node" -p 'process.env.LD_LIBRARY_PATH')" == "$node_lib" ]]
custom=/custom/image/lib:/custom/extension/lib
[[ "$(LD_LIBRARY_PATH="$custom" "$node_current/bin/node" -p 'process.env.LD_LIBRARY_PATH')" == "$node_lib:$custom" ]]
already="/before:$node_lib:/after"; actual="$(LD_LIBRARY_PATH="$already" "$node_current/bin/node" -p 'process.env.LD_LIBRARY_PATH')"
[[ "$actual" == "$already" && "$(awk -F: -v p="$node_lib" '{n=0;for(i=1;i<=NF;i++)if($i==p)n++;print n}'<<<"$actual")" == 1 ]]
mapfile -t args < <("$node_current/bin/node" -e 'for(const x of process.argv.slice(1))console.log(x)' 'one value' two)
[[ "${args[0]}" == 'one value' && "${args[1]}" == two ]]
set +e; "$node_current/bin/node" -e 'process.exit(37)'; rc=$?; set -e; [[ "$rc" == 37 ]]
hostile="$TEST_TMP/hostile"; mkdir "$hostile"; printf '#!/bin/sh\nexit 99\n' >"$hostile/node"; chmod 755 "$hostile/node"
PATH="$hostile:/usr/bin:/bin" "$node_current/bin/npm" --version >/dev/null
PATH="$hostile:/usr/bin:/bin" "$node_current/bin/npx" --version >/dev/null
node_count="$(generation_count "$SOFTWARE_ROOT/node")"; [[ "$($NODE_RECONCILE)" == "$node_a" ]]; [[ "$(generation_count "$SOFTWARE_ROOT/node")" == "$node_count" ]]
"$NODE_RECONCILE" >"$TEST_TMP/node-concurrent-1" & n1=$!; "$NODE_RECONCILE" >"$TEST_TMP/node-concurrent-2" & n2=$!; wait "$n1"; wait "$n2"
[[ "$(cat "$TEST_TMP/node-concurrent-1")" == "$node_a" && "$(cat "$TEST_TMP/node-concurrent-2")" == "$node_a" ]]
assert_clean_component "$SOFTWARE_ROOT/node"

# Existing complete Node generations are revalidated and wrapper corruption fails closed.
node_wrapper="$SOFTWARE_ROOT/node/generations/$node_a/bin/node"; cp "$node_wrapper" "$TEST_TMP/node-wrapper.good"
printf '#!/bin/sh\nexit 0\n' >"$node_wrapper"; chmod 755 "$node_wrapper"; node_cur="$(link_target "$SOFTWARE_ROOT/node/current")"; node_count="$(generation_count "$SOFTWARE_ROOT/node")"
if "$NODE_RECONCILE" >/dev/null 2>&1; then exit 1; fi
[[ "$(link_target "$SOFTWARE_ROOT/node/current")" == "$node_cur" && "$(generation_count "$SOFTWARE_ROOT/node")" == "$node_count" ]]
mv "$TEST_TMP/node-wrapper.good" "$node_wrapper"; assert_clean_component "$SOFTWARE_ROOT/node"

# Node B uses the same source-image identity and differs only by a harmless npm-tree fixture marker.
npm_b="$TEST_TMP/npm-b"; cp -a "$NPM_SRC" "$npm_b"; printf '%s\n' 'generation-b' >"$npm_b/.hermes-poc-generation-b"
export NPM_SRC="$npm_b" SOURCE_IMAGE_DIGEST="$TEST_SOURCE_DIGEST"
node_b="$($NODE_RECONCILE)"; [[ "$node_b" != "$node_a" ]]
[[ "$node_b" =~ ^[0-9a-f]{64}$ && "$(wc -l <<<"$node_b")" == 1 ]]
assert_metadata_roots "$SOFTWARE_ROOT/node/generations/$node_b/metadata.json" node "$node_b" "$TEST_SOURCE_DIGEST"
[[ "$(link_target "$SOFTWARE_ROOT/node/current")" == "generations/$node_b" && "$(link_target "$SOFTWARE_ROOT/node/previous")" == "generations/$node_a" ]]
"$ROLLBACK" node >/dev/null
[[ "$(link_target "$SOFTWARE_ROOT/node/current")" == "generations/$node_a" && "$(link_target "$SOFTWARE_ROOT/node/previous")" == "generations/$node_b" ]]

# Corrupt previous payload is rejected without exchanging links.
previous_node="$SOFTWARE_ROOT/node/generations/$node_b/libexec/node"; cp "$previous_node" "$TEST_TMP/previous-node.good"; printf 'corrupt\n' >"$previous_node"; chmod 755 "$previous_node"
node_cur="$(link_target "$SOFTWARE_ROOT/node/current")"; node_prev="$(link_target "$SOFTWARE_ROOT/node/previous")"
if "$ROLLBACK" node >/dev/null 2>&1; then exit 1; fi
[[ "$(link_target "$SOFTWARE_ROOT/node/current")" == "$node_cur" && "$(link_target "$SOFTWARE_ROOT/node/previous")" == "$node_prev" ]]
mv "$TEST_TMP/previous-node.good" "$previous_node"

# Invalid Node inputs preserve links and generation count.
export NODE_SRC="$NODE_SRC_ORIGINAL"
export NPM_SRC="$NPM_SRC_ORIGINAL"
node_before_current="$(link_target "$SOFTWARE_ROOT/node/current")"; node_before_previous="$(link_target "$SOFTWARE_ROOT/node/previous")"; node_before_count="$(generation_count "$SOFTWARE_ROOT/node")"
assert_node_failure(){ if "$NODE_RECONCILE" >"$TEST_TMP/node-bad.log" 2>&1;then exit 1;fi; [[ "$(link_target "$SOFTWARE_ROOT/node/current")" == "$node_before_current" && "$(link_target "$SOFTWARE_ROOT/node/previous")" == "$node_before_previous" && "$(generation_count "$SOFTWARE_ROOT/node")" == "$node_before_count" ]]; assert_clean_component "$SOFTWARE_ROOT/node"; }
export SOURCE_IMAGE_DIGEST=sha256:bad; assert_node_failure
export SOURCE_IMAGE_DIGEST="$TEST_SOURCE_DIGEST"; real_node="$NODE_SRC"; printf 'not elf\n'>"$TEST_TMP/not-elf"; chmod 755 "$TEST_TMP/not-elf"; export NODE_SRC="$TEST_TMP/not-elf"; assert_node_failure; export NODE_SRC="$real_node"
real_npm="$NPM_SRC"; export NPM_SRC="$TEST_TMP/missing-npm"; assert_node_failure
cp -a "$real_npm" "$TEST_TMP/npm-bad"; export NPM_SRC="$TEST_TMP/npm-bad"; rm "$NPM_SRC/bin/npm-cli.js"; assert_node_failure; export NPM_SRC="$real_npm"
printf '#!/bin/sh\nexit 42\n'>"$TEST_TMP/fail-ldd"; chmod 755 "$TEST_TMP/fail-ldd"; export LDD_BIN="$TEST_TMP/fail-ldd"; assert_node_failure; unset LDD_BIN

# Exercise the actual Node loader contract: copy real libatomic when resolved,
# otherwise prove the generation contains no synthetic or stale loader file.
real_atomic="$(ldd "$NODE_SRC_ORIGINAL" | awk '$1=="libatomic.so.1" && $3~/^\// {print $3;exit}')"
node_a_atomic="$SOFTWARE_ROOT/node/generations/$node_a/lib/libatomic.so.1"
if [[ -n "$real_atomic" ]]; then
  [[ -f "$real_atomic" ]]
  [[ -f "$node_a_atomic" && ! -L "$node_a_atomic" ]]
  [[ "$(sha256sum "$node_a_atomic"|cut -d' ' -f1)" == "$(sha256sum "$real_atomic"|cut -d' ' -f1)" ]]
else
  [[ ! -e "$node_a_atomic" && ! -L "$node_a_atomic" ]]
fi

# An unresolved libatomic dependency fails without link or generation-count drift.
cat >"$TEST_TMP/unresolved-libatomic-ldd" <<'LDD'
#!/bin/sh
printf '%s\n' 'libatomic.so.1 => not found'
LDD
chmod 755 "$TEST_TMP/unresolved-libatomic-ldd"
export NODE_SRC="$NODE_SRC_ORIGINAL" NPM_SRC="$NPM_SRC_ORIGINAL" SOURCE_IMAGE_DIGEST="$TEST_SOURCE_DIGEST" LDD_BIN="$TEST_TMP/unresolved-libatomic-ldd"
node_before_current="$(link_target "$SOFTWARE_ROOT/node/current")"; node_before_previous="$(link_target "$SOFTWARE_ROOT/node/previous")"; node_before_count="$(generation_count "$SOFTWARE_ROOT/node")"
assert_node_failure
unset LDD_BIN

# The final selected state is deterministic for separate-Pod persistence checks.
[[ "$(link_target "$SOFTWARE_ROOT/node/current")" == "generations/$node_a" ]]
[[ "$(link_target "$SOFTWARE_ROOT/node/previous")" == "generations/$node_b" ]]

# Combined consumer PATH uses selected immutable generations.
export PATH="$SOFTWARE_ROOT/python/current/bin:$SOFTWARE_ROOT/node/current/bin:$hostile:/usr/bin:/bin"
[[ "$(command -v python)" == "$SOFTWARE_ROOT/python/current/bin/python" && "$(command -v node)" == "$SOFTWARE_ROOT/node/current/bin/node" ]]
python -c 'import pyfiglet,six'; pyfiglet OK >/dev/null; node --version >/dev/null; npm --version >/dev/null; npx --version >/dev/null
assert_clean_component "$SOFTWARE_ROOT/python"; assert_clean_component "$SOFTWARE_ROOT/node"
mapfile -t software_top < <(find "$SOFTWARE_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
[[ "${software_top[*]}" == 'node python' ]]
printf 'software generation lifecycle tests passed root=%s python_current=%s python_previous=%s node_current=%s node_previous=%s\n' "$SOFTWARE_ROOT" "$(readlink "$SOFTWARE_ROOT/python/current")" "$(readlink "$SOFTWARE_ROOT/python/previous")" "$(readlink "$SOFTWARE_ROOT/node/current")" "$(readlink "$SOFTWARE_ROOT/node/previous")"
