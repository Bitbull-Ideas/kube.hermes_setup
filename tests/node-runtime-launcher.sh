#!/usr/bin/env bash
# Verify the production WebUI Node launcher preserves the image loader environment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-production-node-launcher.XXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

(
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/examples/hermes.env.example"
  set +a
  export HERMES_INSTALL_LIB_ONLY=true
  # shellcheck disable=SC1091
  source "$ROOT_DIR/install.sh"
  export HERMES_DASHBOARD_ENABLED=false
  export HERMES_WEBUI_ENABLED=true
  export HERMES_BROWSER_ENABLED=false
  export HERMES_BOOTSTRAP_MODE=disabled
  export HERMES_ADDON_REQUIREMENTS=
  export WEBUI_HOST=webui.example.com
  export HERMES_RENDER_DIR="$TMP_DIR/render"
  prepare_paths
  prepare_defaults
  mkdir -p "$RENDER_DIR"
  python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$MANIFEST_OUT"
)

python3 - "$TMP_DIR/render/hermes.yaml" "$TMP_DIR/init.sh" <<'PY'
import sys,yaml
manifest,output=sys.argv[1:]
docs=[x for x in yaml.safe_load_all(open(manifest)) if x]
webui=next(x for x in docs if x.get('kind')=='Deployment' and x['metadata']['name']=='hermes-webui')
pod=webui['spec']['template']['spec']
container=next(x for x in pod['containers'] if x['name']=='hermes-webui')
env={x['name']:x for x in container.get('env',[])}
assert 'LD_LIBRARY_PATH' not in env, 'WebUI still replaces the image-defined LD_LIBRARY_PATH'
init=next(x for x in pod['initContainers'] if x['name']=='prepare-browser-cli')
script=init['args'][0]
assert 'node_root=/opt/data/node' in script
assert '"$node_root/libexec/node"' in script
assert 'NODE_LAUNCHER' in script
assert "[ -n \"$node_atomic_lib\" ] ||" not in script
open(output,'w').write(script)
PY

mkdir -p \
  "$TMP_DIR/source/bin" \
  "$TMP_DIR/source/npm/bin" \
  "$TMP_DIR/source/agent-node-modules" \
  "$TMP_DIR/fake-bin" \
  "$TMP_DIR/runtime"
cat > "$TMP_DIR/source/bin/node" <<'NODE'
#!/bin/sh
case "${1-}" in
  env) printenv LD_LIBRARY_PATH 2>/dev/null || true ;;
  args) shift; printf '%s\n' "$@" ;;
  exit) exit "$2" ;;
  */bin/npm|*/npm-cli.js) printf '%s\n' npm-ok ;;
  */bin/npx|*/npx-cli.js) printf '%s\n' npx-ok ;;
  *) printf 'unexpected payload argument: %s\n' "${1-}" >&2; exit 64 ;;
esac
NODE
chmod 755 "$TMP_DIR/source/bin/node"
printf '%s\n' '#!/usr/bin/env node' > "$TMP_DIR/source/npm/bin/npm-cli.js"
printf '%s\n' '#!/usr/bin/env node' > "$TMP_DIR/source/npm/bin/npx-cli.js"
printf '%s\n' '{}' > "$TMP_DIR/source/npm/package.json"
chmod 755 "$TMP_DIR/source/npm/bin/"*.js
cat > "$TMP_DIR/fake-bin/ldd" <<'LDD'
#!/bin/sh
printf '%s\n' 'linux-vdso.so.1 (0x0000000000000000)'
LDD
chmod 755 "$TMP_DIR/fake-bin/ldd"

python3 - "$TMP_DIR/init.sh" "$TMP_DIR/runtime" "$TMP_DIR/source" <<'PY'
from pathlib import Path
import sys
script,runtime,source=map(Path,sys.argv[1:])
text=script.read_text()
text=text.replace('/opt/data/node',str(runtime))
text=text.replace('/usr/local/bin/node',str(source/'bin/node'))
text=text.replace('/usr/local/lib/node_modules/npm',str(source/'npm'))
text=text.replace('/home/hermeswebui/.hermes/hermes-agent/node_modules',str(source/'agent-node-modules'))
text=text.replace('chown -R 10000:10000',': # ownership skipped in fixture')
script.write_text(text)
PY
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh"

NODE="$TMP_DIR/runtime/bin/node"
NPM="$TMP_DIR/runtime/bin/npm"
NPX="$TMP_DIR/runtime/bin/npx"
PRIVATE="$TMP_DIR/runtime/lib"
[[ -x "$NODE" && -x "$TMP_DIR/runtime/libexec/node" ]]
[[ ! -e "$PRIVATE/libatomic.so.1" && ! -L "$PRIVATE/libatomic.so.1" ]]
unset LD_LIBRARY_PATH || true
[[ "$("$NODE" env)" == "$PRIVATE" ]]
custom=/custom/image/lib:/custom/extension/lib
[[ "$(LD_LIBRARY_PATH="$custom" "$NODE" env)" == "$PRIVATE:$custom" ]]
already="/before:$PRIVATE:/after"
[[ "$(LD_LIBRARY_PATH="$already" "$NODE" env)" == "$already" ]]
mapfile -t args < <("$NODE" args 'one value' two)
[[ "${args[0]}" == 'one value' && "${args[1]}" == two ]]
set +e
"$NODE" exit 37
rc=$?
set -e
[[ "$rc" == 37 ]]
npm_result="$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPM" --version)"
npx_result="$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPX" --version)"
[[ "$npm_result" == npm-ok ]]
[[ "$npx_result" == npx-ok ]]

printf 'production Node launcher tests passed\n'
