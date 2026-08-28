#!/usr/bin/env python3
"""Independently verify the persisted software-generation state."""
import hashlib
import importlib.metadata
import json
import os
import pathlib
import re
import stat
import subprocess
import sys

root = pathlib.Path(os.environ.get("SOFTWARE_ROOT", "/software")).resolve(strict=True)
expected_root = pathlib.Path(os.environ.get("EXPECTED_SOFTWARE_ROOT", "/software")).resolve(strict=True)
expected_digest = os.environ["TEST_SOURCE_DIGEST"]
assert root == expected_root, f"software root mismatch: actual={root} expected={expected_root}"
assert re.fullmatch(r"sha256:[0-9a-f]{64}", expected_digest)
assert sorted(p.name for p in root.iterdir()) == ["node", "python"]


def tree_hash(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    for p in sorted(path.rglob("*"), key=lambda x: x.relative_to(path).as_posix()):
        rel = p.relative_to(path).as_posix()
        st = p.lstat()
        mode = stat.S_IMODE(st.st_mode)
        if p.is_symlink():
            kind, payload = "L", os.readlink(p).encode()
        elif p.is_file():
            kind, payload = "F", p.read_bytes()
        elif p.is_dir():
            kind, payload = "D", b""
        else:
            raise AssertionError(f"unsupported entry: {p}")
        h.update(f"{rel}\0{kind}\0{mode:o}\0".encode())
        h.update(payload)
        h.update(b"\0")
    return h.hexdigest()


def generation_state(component: str):
    base = root / component
    assert list((base / "staging").iterdir()) == []
    generations = sorted(p for p in (base / "generations").iterdir() if p.is_dir())
    assert len(generations) == 2
    for generation in generations:
        assert re.fullmatch(r"[0-9a-f]{64}", generation.name)
        assert (generation / ".complete").is_file()
    links = {}
    for name in ("current", "previous"):
        link = base / name
        assert link.is_symlink()
        target = os.readlink(link)
        assert re.fullmatch(r"generations/[0-9a-f]{64}", target)
        path = base / target
        assert path.is_dir() and (path / ".complete").is_file()
        links[name] = path
    assert links["current"] != links["previous"]
    return base, generations, links


py_base, _, py = generation_state("python")
node_base, _, node = generation_state("node")

for name, generation in (("current", py["current"]), ("previous", py["previous"])):
    meta = json.loads((generation / "metadata.json").read_text())
    assert meta["component"] == "python"
    assert meta["software_root"] == str(root)
    assert meta["component_root"] == str(py_base)
    assert meta["generation_path"] == str(generation)
    assert meta["generation_hash"] == generation.name
    assert meta["source_digest"] == expected_digest
    code = (
        "import importlib.metadata as m,json,sysconfig;"
        "i={'pip','setuptools','wheel'};"
        "print(json.dumps(sorted((d.metadata.get('Name') or d.name).lower().replace('_','-')+'=='+d.version "
        "for d in m.distributions(path=[sysconfig.get_paths()['purelib']]) if (d.metadata.get('Name') or d.name).lower().replace('_','-') not in i)))"
    )
    actual = json.loads(subprocess.check_output([str(generation / "bin/python"), "-c", code], text=True))
    assert actual == meta["installed"]
    if name == "current":
        assert actual == ["pyfiglet==1.0.4", "six==1.17.0"]
        subprocess.check_call([str(generation / "bin/python"), "-c", "import pyfiglet,six"])
        subprocess.check_call([str(generation / "bin/pyfiglet"), "OK"], stdout=subprocess.DEVNULL)
    else:
        assert actual == ["pyfiglet==1.0.4"]
        rc = subprocess.run([str(generation / "bin/python"), "-c", "import six"], capture_output=True).returncode
        assert rc != 0

for generation in node.values():
    meta = json.loads((generation / "metadata.json").read_text())
    assert meta["component"] == "node"
    assert meta["software_root"] == str(root)
    assert meta["component_root"] == str(node_base)
    assert meta["generation_path"] == str(generation)
    assert meta["generation_hash"] == generation.name
    assert meta["source_digest"] == expected_digest
    assert hashlib.sha256((generation / "libexec/node").read_bytes()).hexdigest() == meta["node_sha256"]
    assert tree_hash(generation / "lib/node_modules/npm") == meta["npm_tree_sha256"]
    for executable in ("node", "npm", "npx"):
        wrapper = generation / "bin" / executable
        assert hashlib.sha256(wrapper.read_bytes()).hexdigest() == meta["wrapper_sha256"][executable]
        subprocess.check_call([str(wrapper), "--version"], stdout=subprocess.DEVNULL)
    atomic = generation / "lib/libatomic.so.1"
    if meta["libatomic_sha256"] == "none":
        assert not atomic.exists() and not atomic.is_symlink()
    else:
        assert atomic.is_file() and not atomic.is_symlink()
        assert hashlib.sha256(atomic.read_bytes()).hexdigest() == meta["libatomic_sha256"]

hostile = pathlib.Path(os.environ.get("TEST_TMP", "/test-tmp")) / "hostile-node"
hostile.parent.mkdir(parents=True, exist_ok=True)
hostile.write_text("#!/bin/sh\nexit 99\n")
hostile.chmod(0o755)
env = os.environ.copy()
env["PATH"] = f"{hostile.parent}:/usr/bin:/bin"
subprocess.check_call([str(node["current"] / "bin/npm"), "--version"], env=env, stdout=subprocess.DEVNULL)
subprocess.check_call([str(node["current"] / "bin/npx"), "--version"], env=env, stdout=subprocess.DEVNULL)
print("persisted-state-verifier=PASS")
print(f"python_current={py['current'].name} python_previous={py['previous'].name}")
print(f"node_current={node['current'].name} node_previous={node['previous'].name}")
