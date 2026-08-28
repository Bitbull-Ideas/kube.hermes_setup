#!/usr/bin/env python3
"""Conservatively verify Node and metadata from a non-Agent image."""
import json
import os
import pathlib
import re
import subprocess

root = pathlib.Path(os.environ.get("SOFTWARE_ROOT", "/software")).resolve(strict=True)
expected_root = pathlib.Path(os.environ.get("EXPECTED_SOFTWARE_ROOT", "/software")).resolve(strict=True)
expected_digest = os.environ["TEST_SOURCE_DIGEST"]
assert root == expected_root
assert re.fullmatch(r"sha256:[0-9a-f]{64}", expected_digest)
assert sorted(p.name for p in root.iterdir()) == ["node", "python"]

links = {}
for component in ("python", "node"):
    base = root / component
    assert list((base / "staging").iterdir()) == []
    generations = sorted(p for p in (base / "generations").iterdir() if p.is_dir())
    assert len(generations) == 2
    for generation in generations:
        assert re.fullmatch(r"[0-9a-f]{64}", generation.name)
        assert (generation / ".complete").is_file()
        metadata = json.loads((generation / "metadata.json").read_text())
        assert metadata["component"] == component
        assert metadata["software_root"] == str(root)
        assert metadata["component_root"] == str(base)
        assert metadata["generation_path"] == str(generation)
        assert metadata["generation_hash"] == generation.name
        assert metadata["source_digest"] == expected_digest
    links[component] = {}
    for name in ("current", "previous"):
        link = base / name
        assert link.is_symlink()
        target = os.readlink(link)
        assert re.fullmatch(r"generations/[0-9a-f]{64}", target)
        path = base / target
        assert (path / ".complete").is_file()
        links[component][name] = path
    assert links[component]["current"] != links[component]["previous"]

node = links["node"]["current"]
private = str(node / "lib")
inherited = os.environ["EXPECTED_INHERITED_LD_LIBRARY_PATH"]
env = os.environ.copy()
env["LD_LIBRARY_PATH"] = inherited
actual = subprocess.check_output([str(node / "bin/node"), "-p", "process.env.LD_LIBRARY_PATH"], env=env, text=True).strip()
assert actual == f"{private}:{inherited}"
assert actual.split(":").count(private) == 1
hostile_dir = pathlib.Path(os.environ.get("TEST_TMP", "/test-tmp")) / "hostile"
hostile_dir.mkdir(parents=True, exist_ok=True)
hostile_node = hostile_dir / "node"
hostile_node.write_text("#!/bin/sh\nexit 99\n")
hostile_node.chmod(0o755)
env["PATH"] = f"{hostile_dir}:/usr/bin:/bin"
for executable in ("node", "npm", "npx"):
    subprocess.check_call([str(node / "bin" / executable), "--version"], env=env, stdout=subprocess.DEVNULL)
print("webui-state-verifier=PASS")
print(f"effective_ld_library_path={actual}")
print(f"python_metadata_only_current={links['python']['current'].name}")
