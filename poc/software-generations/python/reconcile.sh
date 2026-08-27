#!/usr/bin/env bash
# Build and atomically activate one immutable Python generation.
set -euo pipefail

RECONCILER_VERSION=python-reconciler-v2
: "${SOFTWARE_ROOT:?SOFTWARE_ROOT is required}"
: "${PYTHON_BIN:?PYTHON_BIN is required}"
: "${LOCKFILE:?LOCKFILE is required}"
: "${BUILDER_IMAGE_DIGEST:?BUILDER_IMAGE_DIGEST is required}"
[[ "$BUILDER_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { printf '%s\n' 'invalid BUILDER_IMAGE_DIGEST' >&2; exit 2; }
[[ -f "$LOCKFILE" && ! -L "$LOCKFILE" ]] || { printf '%s\n' 'LOCKFILE must be a regular non-symlink file' >&2; exit 2; }
PYTHON_BIN="$(readlink -f -- "$PYTHON_BIN")"
[[ -f "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || { printf '%s\n' 'invalid PYTHON_BIN' >&2; exit 2; }
command -v flock >/dev/null 2>&1 || { printf '%s\n' 'flock is required' >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { printf '%s\n' 'sha256sum is required' >&2; exit 2; }

python3 - "$SOFTWARE_ROOT" <<'PY'
import pathlib,sys
raw=sys.argv[1]
assert raw.startswith('/') and raw != '/'
assert not any(ord(c)<32 or ord(c)==127 for c in raw)
assert '..' not in pathlib.PurePath(raw).parts
p=pathlib.Path(raw); p.mkdir(parents=True,exist_ok=True)
assert p.is_dir() and str(p.resolve(strict=True)) != '/'
PY
SOFTWARE_ROOT="$(python3 - "$SOFTWARE_ROOT" <<'PY'
import pathlib,sys
print(pathlib.Path(sys.argv[1]).resolve(strict=True))
PY
)"
component="$SOFTWARE_ROOT/python"
mkdir -p "$component"
exec 9>"$component/.lock"
flock 9
mkdir -p "$component/generations" "$component/staging"
# Python never builds under staging; remove residue left by interrupted older PoC revisions.
for stale in "$component/staging/"*; do
  [[ -e "$stale" ]] || continue
  case "$stale" in "$component"/staging/*) rm -rf -- "$stale" ;; *) exit 2 ;; esac
done

reconciler_sha="$(sha256sum "$0" | cut -d' ' -f1)"
lock_sha="$(sha256sum "$LOCKFILE" | cut -d' ' -f1)"
runtime_json="$($PYTHON_BIN - <<'PY'
import json,sys,sysconfig
print(json.dumps({'python_version':sys.version.split()[0],'cache_tag':sys.implementation.cache_tag,'soabi':sysconfig.get_config_var('SOABI') or ''},sort_keys=True,separators=(',',':')))
PY
)"
expected_json="$(python3 - "$LOCKFILE" <<'PY'
import json,re,sys
items=[]
for line in open(sys.argv[1]):
 m=re.match(r'^([A-Za-z0-9_.-]+)==([^ \\]+)',line)
 if m: items.append(m.group(1).lower().replace('_','-')+'=='+m.group(2))
print(json.dumps(sorted(set(items)),separators=(',',':')))
PY
)"
generation="$(printf '%s\n' "$RECONCILER_VERSION" "reconciler=$reconciler_sha" "root=$SOFTWARE_ROOT" "source=$BUILDER_IMAGE_DIGEST" "lock=$lock_sha" "runtime=$runtime_json" "inventory=$expected_json" | sha256sum | cut -d' ' -f1)"
final="$component/generations/$generation"
created_final=false
success=false
remove_final(){ case "$final" in "$component"/generations/"$generation") rm -rf -- "$final" ;; *) return 1 ;; esac; }
cleanup(){ rc=$?; trap - EXIT HUP INT TERM; set +e; if [[ "$success" != true && "$created_final" == true && -d "$final" && ! -f "$final/.complete" ]];then remove_final;fi; exit "$rc"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

validate_generation(){
  root="$1"
  [[ -d "$root" && -f "$root/.complete" && -f "$root/metadata.json" && -f "$root/requirements.lock" && -x "$root/bin/python" ]] || return 1
  [[ "$(sha256sum "$root/requirements.lock"|cut -d' ' -f1)" == "$lock_sha" ]] || return 1
  "$root/bin/python" - "$root" "$SOFTWARE_ROOT" "$component" "$final" "$generation" "$BUILDER_IMAGE_DIGEST" "$lock_sha" "$reconciler_sha" "$RECONCILER_VERSION" "$runtime_json" "$expected_json" <<'PY'
import importlib.metadata as md,json,pathlib,sys
root,sroot,croot,gpath,gh,digest,lsha,rsha,version,runtime_json,expected_json=sys.argv[1:]
d=json.loads(pathlib.Path(root,'metadata.json').read_text()); runtime=json.loads(runtime_json); expected=json.loads(expected_json)
assert d['component']=='python' and d['software_root']==sroot and d['component_root']==croot and d['generation_path']==gpath==root
assert d['generation_hash']==gh and d['source_digest']==digest and d['lockfile_sha256']==lsha
assert d['reconciler_sha256']==rsha and d['reconciler_version']==version
for k,v in runtime.items(): assert d[k]==v
ignored={'pip','setuptools','wheel'}
actual=sorted((x.metadata.get('Name') or x.name).lower().replace('_','-')+'=='+x.version for x in md.distributions() if (x.metadata.get('Name') or x.name).lower().replace('_','-') not in ignored)
assert actual==expected==d['installed']
for p in list(pathlib.Path(root,'bin').iterdir())+[pathlib.Path(root,'pyvenv.cfg')]:
 if not p.is_file() or p.is_symlink(): continue
 data=p.read_bytes()
 if data.startswith(b'#!'):
  assert str(pathlib.Path(root,'bin')).encode() in data.split(b'\n',1)[0]
  assert b'/staging/' not in data.split(b'\n',1)[0]
 if p.name in {'activate','activate.csh','activate.fish','pyvenv.cfg'}: assert b'/staging/' not in data
PY
}
activate(){
 target="generations/$generation"; old="$(readlink "$component/current" 2>/dev/null||true)"; [[ "$old" != "$target" ]]||return 0
 if [[ -n "$old" ]];then
  [[ "$old" =~ ^generations/[0-9a-f]{64}$ && -f "$component/$old/.complete" ]]||return 1
  prior="$(readlink "$component/previous" 2>/dev/null||true)"; had_prior=false;[[ -z "$prior" ]]||had_prior=true
  ln -s "$old" "$component/.previous.$$";mv -Tf "$component/.previous.$$" "$component/previous"
 fi
 ln -s "$target" "$component/.current.$$"
 if ! mv -Tf "$component/.current.$$" "$component/current";then
  rm -f "$component/.current.$$"
  if [[ -n "${old:-}" ]];then if [[ "$had_prior" == true ]];then ln -s "$prior" "$component/.restore.$$";mv -Tf "$component/.restore.$$" "$component/previous";else rm -f "$component/previous";fi;fi
  return 1
 fi
}

if [[ -d "$final" ]];then
 if [[ ! -f "$final/.complete" ]];then remove_final
 else validate_generation "$final"||{ printf '%s\n' 'existing complete Python generation is corrupt' >&2;exit 1;};activate;success=true;printf '%s\n' "$generation";exit 0
 fi
fi
mkdir "$final";created_final=true
"$PYTHON_BIN" -m venv --copies "$final"
"$final/bin/python" -m pip install --disable-pip-version-check --require-hashes --no-deps -r "$LOCKFILE"
cp "$LOCKFILE" "$final/requirements.lock"
installed_json="$($final/bin/python - <<'PY'
import importlib.metadata as md,json
ignored={'pip','setuptools','wheel'}
print(json.dumps(sorted((x.metadata.get('Name') or x.name).lower().replace('_','-')+'=='+x.version for x in md.distributions() if (x.metadata.get('Name') or x.name).lower().replace('_','-') not in ignored),separators=(',',':')))
PY
)"
[[ "$installed_json" == "$expected_json" ]] || { printf '%s\n' 'Python inventory mismatch' >&2; exit 1; }
python3 - "$final/metadata.json" "$SOFTWARE_ROOT" "$component" "$final" "$generation" "$BUILDER_IMAGE_DIGEST" "$lock_sha" "$reconciler_sha" "$RECONCILER_VERSION" "$runtime_json" "$installed_json" <<'PY'
import json,pathlib,sys
p,sroot,croot,gpath,gh,digest,lsha,rsha,version,runtime,installed=sys.argv[1:]
d={'schema':1,'component':'python','software_root':sroot,'component_root':croot,'generation_path':gpath,'generation_hash':gh,'source_digest':digest,'lockfile_sha256':lsha,'reconciler_sha256':rsha,'reconciler_version':version,'installed':json.loads(installed),**json.loads(runtime)}
pathlib.Path(p).write_text(json.dumps(d,sort_keys=True,indent=2)+'\n')
PY
# Validate final-path venv before publishing completeness.
"$final/bin/python" -c 'import importlib.metadata; list(importlib.metadata.distributions())'
printf '%s\n' complete >"$final/.complete"
validate_generation "$final"
created_final=false
activate
success=true
printf '%s\n' "$generation"
