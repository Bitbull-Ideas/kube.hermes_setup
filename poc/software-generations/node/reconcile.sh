#!/usr/bin/env bash
# Build and atomically activate one immutable Node software generation.
set -euo pipefail

RECONCILER_VERSION=node-reconciler-v1
: "${SOFTWARE_ROOT:?SOFTWARE_ROOT is required}"
: "${NODE_SRC:?NODE_SRC is required}"
: "${NPM_SRC:?NPM_SRC is required}"
: "${SOURCE_IMAGE_DIGEST:?SOURCE_IMAGE_DIGEST is required}"
LDD_BIN="${LDD_BIN:-ldd}"

python3 - "$SOFTWARE_ROOT" <<'PY'
import pathlib,sys
raw=sys.argv[1]
assert raw.startswith('/') and raw != '/'
assert not any(ord(c)<32 or ord(c)==127 for c in raw)
assert '..' not in pathlib.PurePath(raw).parts
p=pathlib.Path(raw)
assert p.exists() and p.is_dir()
assert str(p.resolve(strict=True)) != '/'
PY
SOFTWARE_ROOT="$(python3 - "$SOFTWARE_ROOT" <<'PY'
import pathlib,sys
print(pathlib.Path(sys.argv[1]).resolve(strict=True))
PY
)"
[[ "$SOURCE_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { printf '%s\n' 'invalid SOURCE_IMAGE_DIGEST' >&2; exit 2; }
[[ -f "$NODE_SRC" && ! -L "$NODE_SRC" && -x "$NODE_SRC" ]] || { printf '%s\n' 'NODE_SRC must be a non-symlink executable regular file' >&2; exit 2; }
[[ -d "$NPM_SRC" && ! -L "$NPM_SRC" ]] || { printf '%s\n' 'NPM_SRC must be a non-symlink directory' >&2; exit 2; }
[[ "$(od -An -tx1 -N4 "$NODE_SRC" | tr -d ' \n')" == 7f454c46 ]] || { printf '%s\n' 'NODE_SRC is not ELF' >&2; exit 2; }
for rel in package.json bin/npm-cli.js bin/npx-cli.js; do
  [[ -f "$NPM_SRC/$rel" && ! -L "$NPM_SRC/$rel" ]] || { printf 'invalid npm source: %s\n' "$rel" >&2; exit 2; }
done
command -v flock >/dev/null 2>&1 || exit 2

component="$SOFTWARE_ROOT/node"
mkdir -p "$component"
exec 9>"$component/.lock"
flock 9
mkdir -p "$component/generations" "$component/staging"
for stale in "$component/staging/"*; do
  [[ -e "$stale" ]] || continue
  case "$stale" in "$component"/staging/*) rm -rf -- "$stale" ;; *) exit 2 ;; esac
done

if ! ldd_output="$($LDD_BIN "$NODE_SRC" 2>&1)"; then printf '%s\n' "$ldd_output" >&2; printf '%s\n' 'ldd failed' >&2; exit 2; fi
if printf '%s\n' "$ldd_output" | grep -Eq 'libatomic[.]so[.]1[[:space:]]+=>[[:space:]]+not found'; then printf '%s\n' 'required libatomic is unresolved' >&2; exit 2; fi
atomic_path="$(printf '%s\n' "$ldd_output" | awk '$1=="libatomic.so.1" && $3~/^\// {print $3;exit}')"
[[ -z "$atomic_path" || -f "$atomic_path" ]] || { printf '%s\n' 'resolved libatomic is not a file' >&2; exit 2; }
reconciler_sha="$(sha256sum "$0" | cut -d' ' -f1)"
node_sha="$(sha256sum "$NODE_SRC" | cut -d' ' -f1)"
npm_sha="$(python3 - "$NPM_SRC" <<'PY'
import hashlib,os,pathlib,stat,sys
root=pathlib.Path(sys.argv[1]); h=hashlib.sha256()
for p in sorted(root.rglob('*'),key=lambda x:x.relative_to(root).as_posix()):
 rel=p.relative_to(root).as_posix(); st=p.lstat(); mode=stat.S_IMODE(st.st_mode)
 if p.is_symlink(): typ='L'; payload=os.readlink(p).encode()
 elif p.is_file(): typ='F'; payload=p.read_bytes()
 elif p.is_dir(): typ='D'; payload=b''
 else: raise SystemExit(f'unsupported npm entry: {rel}')
 h.update(f'{rel}\0{typ}\0{mode:o}\0'.encode()); h.update(payload); h.update(b'\0')
print(h.hexdigest())
PY
)"
loader_json="$(python3 - "$ldd_output" <<'PY'
import json,re,subprocess,sys
entries=[]
for raw in sys.argv[1].splitlines():
 line=re.sub(r'\s*\(0x[0-9a-fA-F]+\)\s*$','',raw.strip())
 if not line or line.startswith('linux-vdso'): continue
 if '=>' in line:
  name,resolved=(part.strip() for part in line.split('=>',1))
 else:
  parts=line.split(); name=parts[0]; resolved=parts[0] if parts[0].startswith('/') else ''
 entries.append({'name':name,'path':resolved})
try: libc=subprocess.check_output(['ldd','--version'],stderr=subprocess.STDOUT,text=True).splitlines()[0].strip()
except Exception: libc='unknown'
print(json.dumps({'architecture':subprocess.check_output(['uname','-m'],text=True).strip(),'libc':libc,'dependencies':sorted(entries,key=lambda x:(x['name'],x['path']))},sort_keys=True,separators=(',',':')))
PY
)"
atomic_sha=none; [[ -z "$atomic_path" ]] || atomic_sha="$(sha256sum "$atomic_path" | cut -d' ' -f1)"
generation="$(printf '%s\n' "$RECONCILER_VERSION" "reconciler=$reconciler_sha" "root=$SOFTWARE_ROOT" "source=$SOURCE_IMAGE_DIGEST" "node=$node_sha" "npm=$npm_sha" "loader=$loader_json" "atomic=$atomic_sha" | sha256sum | cut -d' ' -f1)"
final="$component/generations/$generation"; stage="$component/staging/$generation.$$"; created_final=false; success=false
remove_stage(){ case "$stage" in "$component"/staging/"$generation".*) rm -rf -- "$stage";; *) return 1;; esac; }
remove_final(){ case "$final" in "$component"/generations/"$generation") rm -rf -- "$final";; *) return 1;; esac; }
cleanup(){ rc=$?; trap - EXIT HUP INT TERM; set +e; [[ ! -e "$stage" ]]||remove_stage; if [[ "$success" != true && "$created_final" == true && -d "$final" && ! -f "$final/.complete" ]];then remove_final;fi; exit "$rc"; }
trap cleanup EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

validate_generation(){
 root="$1"
 [[ -f "$root/.complete" && -x "$root/bin/node" && -x "$root/bin/npm" && -x "$root/bin/npx" && -x "$root/libexec/node" && -f "$root/metadata.json" ]]||return 1
 [[ "$(sha256sum "$root/libexec/node"|cut -d' ' -f1)" == "$node_sha" ]]||return 1
 [[ "$(python3 - "$root/lib/node_modules/npm" <<'PY'
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
)" == "$npm_sha" ]]||return 1
 node_wrapper_sha="$(sha256sum "$root/bin/node"|cut -d' ' -f1)"
 npm_wrapper_sha="$(sha256sum "$root/bin/npm"|cut -d' ' -f1)"
 npx_wrapper_sha="$(sha256sum "$root/bin/npx"|cut -d' ' -f1)"
 python3 - "$root/metadata.json" "$SOFTWARE_ROOT" "$component" "$final" "$generation" "$SOURCE_IMAGE_DIGEST" "$reconciler_sha" "$npm_sha" "$node_sha" "$atomic_sha" "$node_wrapper_sha" "$npm_wrapper_sha" "$npx_wrapper_sha" <<'PY'
import json,pathlib,sys
p,sroot,croot,gpath,gh,digest,rsha,nsha,node_sha,asha,nodew,npmw,npxw=sys.argv[1:];d=json.loads(pathlib.Path(p).read_text())
assert d['component']=='node' and d['software_root']==sroot and d['component_root']==croot and d['generation_path']==gpath
assert d['generation_hash']==gh and d['source_digest']==digest and d['reconciler_sha256']==rsha
assert d['npm_tree_sha256']==nsha and d['node_sha256']==node_sha and d['libatomic_sha256']==asha
assert d['wrapper_sha256']=={'node':nodew,'npm':npmw,'npx':npxw}
PY
 if [[ "$atomic_sha" == none ]]; then
   [[ ! -e "$root/lib/libatomic.so.1" && ! -L "$root/lib/libatomic.so.1" ]] || return 1
 else
   [[ -f "$root/lib/libatomic.so.1" && ! -L "$root/lib/libatomic.so.1" && "$(sha256sum "$root/lib/libatomic.so.1"|cut -d' ' -f1)" == "$atomic_sha" ]] || return 1
 fi
 PATH=/usr/bin:/bin "$root/bin/node" --version >/dev/null && PATH=/usr/bin:/bin "$root/bin/npm" --version >/dev/null && PATH=/usr/bin:/bin "$root/bin/npx" --version >/dev/null
}
activate(){
 target="generations/$generation"; old="$(readlink "$component/current" 2>/dev/null||true)"; [[ "$old" != "$target" ]]||return 0
 if [[ -n "$old" ]];then [[ "$old" =~ ^generations/[0-9a-f]{64}$ && -f "$component/$old/.complete" ]]||return 1; prev="$(readlink "$component/previous" 2>/dev/null||true)"; had_prev=false;[[ -z "$prev" ]]||had_prev=true;ln -s "$old" "$component/.previous.$$";mv -Tf "$component/.previous.$$" "$component/previous";fi
 ln -s "$target" "$component/.current.$$";if ! mv -Tf "$component/.current.$$" "$component/current";then rm -f "$component/.current.$$";if [[ -n "${old:-}" ]];then if [[ "$had_prev" == true ]];then ln -s "$prev" "$component/.restore.$$";mv -Tf "$component/.restore.$$" "$component/previous";else rm -f "$component/previous";fi;fi;return 1;fi
}
if [[ -d "$final" ]];then if [[ ! -f "$final/.complete" ]];then remove_final;else validate_generation "$final"||{ printf '%s\n' 'existing complete Node generation is corrupt' >&2;exit 1;};activate;success=true;printf '%s\n' "$generation";exit 0;fi;fi

mkdir -p "$stage/bin" "$stage/libexec" "$stage/lib/node_modules"
cp "$NODE_SRC" "$stage/libexec/node";chmod 755 "$stage/libexec/node";cp -a "$NPM_SRC" "$stage/lib/node_modules/npm"
if [[ -n "$atomic_path" ]];then cp -pL "$atomic_path" "$stage/lib/libatomic.so.1";chmod 644 "$stage/lib/libatomic.so.1";fi
cat >"$stage/bin/node" <<'EOF'
#!/bin/sh
set -eu
root="$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd)";private="$root/lib";current="${LD_LIBRARY_PATH:-}"
case ":$current:" in *":$private:"*);;*) if [ -n "$current" ];then current="$private:$current";else current="$private";fi;;esac
exec env LD_LIBRARY_PATH="$current" "$root/libexec/node" "$@"
EOF
cat >"$stage/bin/npm" <<'EOF'
#!/bin/sh
set -eu
root="$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd)";exec "$root/bin/node" "$root/lib/node_modules/npm/bin/npm-cli.js" "$@"
EOF
cat >"$stage/bin/npx" <<'EOF'
#!/bin/sh
set -eu
root="$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd)";exec "$root/bin/node" "$root/lib/node_modules/npm/bin/npx-cli.js" "$@"
EOF
chmod 755 "$stage/bin/"*
node_wrapper_sha="$(sha256sum "$stage/bin/node"|cut -d' ' -f1)"
npm_wrapper_sha="$(sha256sum "$stage/bin/npm"|cut -d' ' -f1)"
npx_wrapper_sha="$(sha256sum "$stage/bin/npx"|cut -d' ' -f1)"
python3 - "$stage/metadata.json" "$SOFTWARE_ROOT" "$component" "$final" "$generation" "$SOURCE_IMAGE_DIGEST" "$reconciler_sha" "$RECONCILER_VERSION" "$npm_sha" "$node_sha" "$atomic_sha" "$loader_json" "$node_wrapper_sha" "$npm_wrapper_sha" "$npx_wrapper_sha" <<'PY'
import json,pathlib,sys
p,sroot,croot,gpath,gh,digest,rsha,version,nsha,node_sha,asha,loader,nodew,npmw,npxw=sys.argv[1:]
d={'schema':1,'component':'node','software_root':sroot,'component_root':croot,'generation_path':gpath,'generation_hash':gh,'source_digest':digest,'reconciler_sha256':rsha,'reconciler_version':version,'npm_tree_sha256':nsha,'node_sha256':node_sha,'libatomic_sha256':asha,'wrapper_sha256':{'node':nodew,'npm':npmw,'npx':npxw},**json.loads(loader)}
pathlib.Path(p).write_text(json.dumps(d,sort_keys=True,indent=2)+'\n')
PY
printf '%s\n' complete >"$stage/.complete";mv "$stage" "$final";created_final=true;stage="$component/staging/$generation.$$"
validate_generation "$final";created_final=false;activate;success=true;printf '%s\n' "$generation"
