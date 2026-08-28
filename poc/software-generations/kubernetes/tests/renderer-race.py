#!/usr/bin/env python3
"""Regression tests for renderer no-clobber publication."""
from __future__ import annotations

import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve()
RENDER_PATH = HERE.parents[1] / "render.py"
AGENT = "registry.example.com/hermes-agent@sha256:" + "1" * 64
WEBUI = "registry.example.com/hermes-webui@sha256:" + "2" * 64
EXPECTED = {
    "00-namespace.yaml", "01-configmap.yaml", "02-pvc.yaml",
    "jobs/10-lifecycle.yaml", "jobs/20-persist.yaml",
    "jobs/30-idempotency.yaml", "jobs/40-invalid-lock.yaml",
    "jobs/50-rollback.yaml", "jobs/60-webui.yaml",
    "jobs/70-final-verify.yaml",
}

spec = importlib.util.spec_from_file_location("hermes_qa_renderer", RENDER_PATH)
assert spec and spec.loader
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def command(output: pathlib.Path) -> list[str]:
    return [
        sys.executable, str(RENDER_PATH), "--output", str(output),
        "--agent-image", AGENT, "--webui-image", WEBUI,
        "--uid", "10000", "--gid", "10000",
    ]


def assert_complete(output: pathlib.Path) -> None:
    actual = {p.relative_to(output).as_posix() for p in output.rglob("*.yaml")}
    assert actual == EXPECTED, (actual, EXPECTED)


def deterministic_late_destination() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-render-race.") as temp:
        parent = pathlib.Path(temp)
        output = parent / "rendered"
        original_dump = getattr(renderer, "dump_yaml")
        calls = 0
        destination_inode = None

        def racing_dump(path, obj):
            nonlocal calls, destination_inode
            original_dump(path, obj)
            calls += 1
            if calls == len(EXPECTED):
                output.mkdir(mode=0o700)
                destination_inode = output.stat().st_ino

        setattr(renderer, "dump_yaml", racing_dump)
        try:
            failed = False
            try:
                renderer.render_package(output, AGENT, WEBUI, 10000, 10000)
            except (OSError, ValueError):
                failed = True
            assert failed, "renderer replaced a destination created after preflight"
            assert destination_inode is not None
            assert output.is_dir() and output.stat().st_ino == destination_inode
            assert not list(output.iterdir()), "operator-owned destination was modified"
            assert not list(parent.glob(".rendered.tmp-*")), "renderer temporary directory leaked"
        finally:
            setattr(renderer, "dump_yaml", original_dump)


def concurrent_renderers() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-render-concurrent.") as temp:
        parent = pathlib.Path(temp)
        output = parent / "rendered"
        processes = [
            subprocess.Popen(command(output), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for _ in range(2)
        ]
        results = [process.communicate(timeout=120) + (process.returncode,) for process in processes]
        successes = [result for result in results if result[2] == 0]
        failures = [result for result in results if result[2] != 0]
        assert len(successes) == 1, results
        assert len(failures) == 1, results
        assert "output path already exists" in failures[0][1].lower() or "exists" in failures[0][1].lower(), failures[0]
        assert_complete(output)
        assert not list(parent.glob(".rendered.tmp-*")), "renderer temporary directory leaked"


def main() -> None:
    deterministic_late_destination()
    concurrent_renderers()
    print("Renderer race regressions passed")


if __name__ == "__main__":
    main()
