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
owned_generation=false
validated=false
complete=false
published=false
remove_final(){ case "$final" in "$component"/generations/"$generation") rm -rf -- "$final" ;; *) return 1 ;; esac; }
cleanup(){
 rc=$?; trap - EXIT HUP INT TERM; set +e
 current_target="$(readlink "$component/current" 2>/dev/null || true)"
 if [[ "$owned_generation" == true && "$published" != true && "$current_target" != "generations/$generation" && -d "$final" ]];then remove_final;fi
 exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

validate_generation(){
  local root="$1"
  local require_complete="${2:-true}"
  local actual_lock_sha
  [[ -d "$root" && -f "$root/metadata.json" && -f "$root/requirements.lock" && -x "$root/bin/python" ]] || return 1
  [[ "$require_complete" != true || -f "$root/.complete" ]] || return 1
  actual_lock_sha="$(sha256sum "$root/requirements.lock" | cut -d' ' -f1)" || return 1
  [[ "$actual_lock_sha" == "$lock_sha" ]] || return 1
  "$root/bin/python" - "$root" "$SOFTWARE_ROOT" "$component" "$final" "$generation" "$BUILDER_IMAGE_DIGEST" "$lock_sha" "$reconciler_sha" "$RECONCILER_VERSION" "$runtime_json" "$expected_json" <<'PY' || return 1
import importlib.metadata as md,json,pathlib,sys,sysconfig
root,sroot,croot,gpath,gh,digest,lsha,rsha,version,runtime_json,expected_json=sys.argv[1:]
d=json.loads(pathlib.Path(root,'metadata.json').read_text()); runtime=json.loads(runtime_json); expected=json.loads(expected_json)
assert d['component']=='python' and d['software_root']==sroot and d['component_root']==croot and d['generation_path']==gpath==root
assert d['generation_hash']==gh and d['source_digest']==digest and d['lockfile_sha256']==lsha
assert d['reconciler_sha256']==rsha and d['reconciler_version']==version
for k,v in runtime.items(): assert d[k]==v
ignored={'pip','setuptools','wheel'}
actual=sorted((x.metadata.get('Name') or x.name).lower().replace('_','-')+'=='+x.version for x in md.distributions(path=[sysconfig.get_paths()['purelib']]) if (x.metadata.get('Name') or x.name).lower().replace('_','-') not in ignored)
assert actual==expected==d['installed']
bin_dir=pathlib.Path(root,'bin')
for p in list(bin_dir.iterdir())+[pathlib.Path(root,'pyvenv.cfg')]:
 if not p.is_file() or p.is_symlink(): continue
 data=p.read_bytes()
 if data.startswith(b'\x7fELF'): continue
 if data.startswith(b'#!') or p.name in {'activate','activate.csh','activate.fish','pyvenv.cfg'}:
  assert b'/staging/' not in data
 if data.startswith(b'#!') and p.stat().st_mode & 0o111:
  lines=data.splitlines()[:3]
  allowed={str(bin_dir/'python').encode(),str(bin_dir/'python3').encode()}
  allowed.update(str(x).encode() for x in bin_dir.glob('python3.[0-9]*'))
  direct=lines[0][2:] in allowed
  trampoline=False
  if lines[0]==b'#!/bin/sh' and len(lines)>=3 and lines[2]==b"' '''":
   prefix=b"'''exec' "; suffix=b' "$0" "$@"'
   if lines[1].startswith(prefix) and lines[1].endswith(suffix):
    trampoline=lines[1][len(prefix):-len(suffix)] in allowed
  assert direct or trampoline, (p, lines[:2])
PY
  "$root/bin/python" -m pip --version >/dev/null || return 1
  "$root/bin/python" -m pip check >/dev/null || return 1
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
 if [[ ! -f "$final/.complete" ]];then printf '%s\n' 'existing incomplete Python generation requires manual recovery' >&2;exit 1
 else validate_generation "$final" true||{ printf '%s\n' 'existing complete Python generation is corrupt' >&2;exit 1;};activate;published=true;printf '%s\n' "$generation";exit 0
 fi
fi
mkdir "$final";owned_generation=true
"$PYTHON_BIN" -m venv --copies "$final" >&2
"$final/bin/python" -m pip install --disable-pip-version-check --require-hashes --no-deps -r "$LOCKFILE" >&2
cp "$LOCKFILE" "$final/requirements.lock"
installed_json="$($final/bin/python - <<'PY'
import importlib.metadata as md,json,sysconfig
ignored={'pip','setuptools','wheel'}
print(json.dumps(sorted((x.metadata.get('Name') or x.name).lower().replace('_','-')+'=='+x.version for x in md.distributions(path=[sysconfig.get_paths()['purelib']]) if (x.metadata.get('Name') or x.name).lower().replace('_','-') not in ignored),separators=(',',':')))
PY
)"
if [[ "$installed_json" != "$expected_json" ]]; then
  printf 'Python inventory mismatch expected=%s actual=%s\n' "$expected_json" "$installed_json" >&2
  exit 1
fi
python3 - "$final/metadata.json" "$SOFTWARE_ROOT" "$component" "$final" "$generation" "$BUILDER_IMAGE_DIGEST" "$lock_sha" "$reconciler_sha" "$RECONCILER_VERSION" "$runtime_json" "$installed_json" <<'PY'
import json,pathlib,sys
p,sroot,croot,gpath,gh,digest,lsha,rsha,version,runtime,installed=sys.argv[1:]
d={'schema':1,'component':'python','software_root':sroot,'component_root':croot,'generation_path':gpath,'generation_hash':gh,'source_digest':digest,'lockfile_sha256':lsha,'reconciler_sha256':rsha,'reconciler_version':version,'installed':json.loads(installed),**json.loads(runtime)}
pathlib.Path(p).write_text(json.dumps(d,sort_keys=True,indent=2)+'\n')
PY
# Validate final-path venv before publishing completeness.
validate_generation "$final" false
validated=true
printf '%s\n' complete >"$final/.complete"
complete=true
validate_generation "$final" true
activate
published=true
printf '%s\n' "$generation"
