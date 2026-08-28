#!/usr/bin/env bash
# Atomically exchange current and previous immutable generation links on Linux.
set -euo pipefail

: "${SOFTWARE_ROOT:?SOFTWARE_ROOT is required}"
[[ $# == 1 && "$1" =~ ^(python|node)$ ]] || { printf '%s\n' 'usage: rollback-generation.sh python|node' >&2; exit 2; }
component_name="$1"
SOFTWARE_ROOT="$(python3 - "$SOFTWARE_ROOT" <<'PY'
import pathlib,sys
raw=sys.argv[1]
assert raw.startswith('/') and raw != '/'
assert not any(ord(c)<32 or ord(c)==127 for c in raw)
assert '..' not in pathlib.PurePath(raw).parts
p=pathlib.Path(raw)
assert p.exists() and p.is_dir()
r=p.resolve(strict=True)
assert str(r) != '/'
print(r)
PY
)"
component="$SOFTWARE_ROOT/$component_name"
[[ -d "$component/generations" ]] || { printf '%s\n' 'component generations directory is missing' >&2; exit 2; }
command -v flock >/dev/null 2>&1 || { printf '%s\n' 'flock is required' >&2; exit 2; }
exec 9>"$component/.lock"
flock 9

validate_link() {
  local link="$1" target hash path lock_sha node_sha npm_sha nodew npmw npxw
  [[ -L "$link" ]] || return 1
  target="$(readlink "$link")" || return 1
  [[ "$target" =~ ^generations/[0-9a-f]{64}$ ]] || return 1
  hash="${target#generations/}"
  path="$component/$target"
  [[ -d "$path" && -f "$path/.complete" && -f "$path/metadata.json" ]] || return 1
  python3 - "$path/metadata.json" "$component_name" "$SOFTWARE_ROOT" "$component" "$path" "$hash" <<'PY' || return 1
import json,pathlib,sys
meta,component,software_root,component_root,generation_path,generation_hash=sys.argv[1:]
d=json.loads(pathlib.Path(meta).read_text())
assert d['component']==component
assert d['software_root']==software_root
assert d['component_root']==component_root
assert d['generation_path']==generation_path
assert d['generation_hash']==generation_hash
PY
  if [[ "$component_name" == python ]]; then
    [[ -f "$path/requirements.lock" && -x "$path/bin/python" && ! -L "$path/bin/python" ]] || return 1
    lock_sha="$(sha256sum "$path/requirements.lock" | cut -d' ' -f1)" || return 1
    "$path/bin/python" - "$path" "$lock_sha" <<'PY' || return 1
import importlib.metadata as md,json,pathlib,sys,sysconfig
root=pathlib.Path(sys.argv[1]); lock_sha=sys.argv[2]
d=json.loads((root/'metadata.json').read_text())
assert d['lockfile_sha256']==lock_sha
ignored={'pip','setuptools','wheel'}
actual=sorted(
 (x.metadata.get('Name') or x.name).lower().replace('_','-')+'=='+x.version
 for x in md.distributions(path=[sysconfig.get_paths()['purelib']])
 if (x.metadata.get('Name') or x.name).lower().replace('_','-') not in ignored
)
assert actual==d['installed']
for p in list((root/'bin').iterdir())+[root/'pyvenv.cfg']:
 if not p.is_file() or p.is_symlink(): continue
 data=p.read_bytes()
 if data.startswith(b'#!') or p.name in {'activate','activate.csh','activate.fish','pyvenv.cfg'}:
  assert b'/staging/' not in data
PY
    "$path/bin/python" -m pip --version >/dev/null || return 1
    "$path/bin/python" -m pip check >/dev/null || return 1
  else
    for exe in node npm npx; do [[ -x "$path/bin/$exe" && ! -L "$path/bin/$exe" ]] || return 1; done
    [[ -x "$path/libexec/node" && ! -L "$path/libexec/node" && -d "$path/lib/node_modules/npm" ]] || return 1
    node_sha="$(sha256sum "$path/libexec/node" | cut -d' ' -f1)" || return 1
    npm_sha="$(python3 - "$path/lib/node_modules/npm" <<'PY'
import hashlib,os,pathlib,stat,sys
root=pathlib.Path(sys.argv[1]);h=hashlib.sha256()
for p in sorted(root.rglob('*'),key=lambda x:x.relative_to(root).as_posix()):
 rel=p.relative_to(root).as_posix();st=p.lstat();mode=stat.S_IMODE(st.st_mode)
 if p.is_symlink():typ='L';payload=os.readlink(p).encode()
 elif p.is_file():typ='F';payload=p.read_bytes()
 elif p.is_dir():typ='D';payload=b''
 else:raise SystemExit(1)
 h.update(f'{rel}\0{typ}\0{mode:o}\0'.encode());h.update(payload);h.update(b'\0')
print(h.hexdigest())
PY
)" || return 1
    nodew="$(sha256sum "$path/bin/node"|cut -d' ' -f1)" || return 1
    npmw="$(sha256sum "$path/bin/npm"|cut -d' ' -f1)" || return 1
    npxw="$(sha256sum "$path/bin/npx"|cut -d' ' -f1)" || return 1
    python3 - "$path/metadata.json" "$node_sha" "$npm_sha" "$nodew" "$npmw" "$npxw" "$path" <<'PY' || return 1
import json,pathlib,sys
meta,node_sha,npm_sha,nodew,npmw,npxw,root=sys.argv[1:]
d=json.loads(pathlib.Path(meta).read_text())
assert d['node_sha256']==node_sha and d['npm_tree_sha256']==npm_sha
assert d['wrapper_sha256']=={'node':nodew,'npm':npmw,'npx':npxw}
asha=d['libatomic_sha256']; p=pathlib.Path(root)/'lib/libatomic.so.1'
if asha=='none': assert not p.exists() and not p.is_symlink()
else:
 assert p.is_file() and not p.is_symlink()
 import hashlib
 assert hashlib.sha256(p.read_bytes()).hexdigest()==asha
PY
    PATH=/usr/bin:/bin "$path/bin/node" --version >/dev/null || return 1
    PATH=/usr/bin:/bin "$path/bin/npm" --version >/dev/null || return 1
    PATH=/usr/bin:/bin "$path/bin/npx" --version >/dev/null || return 1
  fi
  printf '%s\n' "$target"
}
current="$(validate_link "$component/current")" || { printf '%s\n' 'invalid current generation link' >&2; exit 1; }
previous="$(validate_link "$component/previous")" || { printf '%s\n' 'invalid previous generation link' >&2; exit 1; }
[[ "$current" != "$previous" ]] || { printf '%s\n' 'current and previous are identical' >&2; exit 1; }

exchange() {
  python3 - "$component/current" "$component/previous" <<'PY'
import ctypes,os,sys
left,right=map(os.fsencode,sys.argv[1:])
libc=ctypes.CDLL(None,use_errno=True)
fn=getattr(libc,'renameat2',None)
if fn is None: raise SystemExit('renameat2 unavailable; refusing fallback')
fn.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
fn.restype=ctypes.c_int
if fn(-100,left,-100,right,2)!=0:
 err=ctypes.get_errno(); raise OSError(err,os.strerror(err))
PY
}
exchange
after_current="$(validate_link "$component/current")" || after_current=invalid
after_previous="$(validate_link "$component/previous")" || after_previous=invalid
if [[ "$after_current" != "$previous" || "$after_previous" != "$current" ]]; then
  exchange || true
  printf '%s\n' 'post-exchange validation failed; rollback exchange attempted' >&2
  exit 1
fi
printf 'current=%s previous=%s\n' "$after_current" "$after_previous"
