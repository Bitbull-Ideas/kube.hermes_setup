#!/usr/bin/env python3
"""Render the isolated Hermes software-generation QA package."""
from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import stat
import sys
import tempfile
from typing import Any, NoReturn

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAMESPACE = "qa"
PVC_NAME = "hermes-software-poc-data"
IMAGE_RE = re.compile(r"^([^@\s]+)@(sha256:[0-9a-f]{64})$")
DECIMAL_RE = re.compile(r"^[0-9]+$")
EXECUTABLE_PATHS = (
    "python/reconcile.sh",
    "node/reconcile.sh",
    "rollback-generation.sh",
    "tests/lifecycle.sh",
    "tests/idempotency.sh",
    "tests/locked-failure.sh",
    "tests/rollback-cycle.sh",
    "verify-state.py",
    "verify-webui-state.js",
    "kubernetes/entrypoints/lifecycle.sh",
    "kubernetes/entrypoints/idempotency.sh",
    "kubernetes/entrypoints/invalid-lock.sh",
)
DATA_PATHS = (
    "requirements-a.lock",
    "requirements-b.lock",
    "requirements-bad.lock",
)
PACKAGED_PATHS = tuple(sorted((*EXECUTABLE_PATHS, *DATA_PATHS)))
AT_FDCWD = -100
RENAME_NOREPLACE = 1
JOB_FILES = (
    ("jobs/10-lifecycle.yaml", "hermes-software-poc-lifecycle", "agent", False,
     ["/bin/bash", "/poc/kubernetes/entrypoints/lifecycle.sh"], 1800),
    ("jobs/20-persist.yaml", "hermes-software-poc-persist", "agent", True,
     ["/opt/hermes/.venv/bin/python", "/poc/verify-state.py"], 300),
    ("jobs/30-idempotency.yaml", "hermes-software-poc-idempotency", "agent", False,
     ["/bin/bash", "/poc/kubernetes/entrypoints/idempotency.sh"], 900),
    ("jobs/40-invalid-lock.yaml", "hermes-software-poc-invalid-lock", "agent", False,
     ["/bin/bash", "/poc/kubernetes/entrypoints/invalid-lock.sh"], 600),
    ("jobs/50-rollback.yaml", "hermes-software-poc-rollback", "agent", False,
     ["/bin/bash", "/poc/tests/rollback-cycle.sh"], 600),
    ("jobs/60-webui.yaml", "hermes-software-poc-webui", "webui", True,
     ["/software/node/current/bin/node", "/poc/verify-webui-state.js"], 300),
    ("jobs/70-final-verify.yaml", "hermes-software-poc-final-verify", "agent", True,
     ["/opt/hermes/.venv/bin/python", "/poc/verify-state.py"], 300),
)


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def validate_image(value: str, label: str) -> str:
    if value.count("@") != 1:
        fail(f"{label} must contain exactly one @")
    match = IMAGE_RE.fullmatch(value)
    if match is None:
        fail(f"{label} must be a whitespace-free repository@sha256:<64 lowercase hex> reference")
    return match.group(2)


def validate_identity(value: str, label: str) -> int:
    if not DECIMAL_RE.fullmatch(value):
        fail(f"{label} must be a decimal integer")
    result = int(value, 10)
    if not 1 <= result <= 2_147_483_647:
        fail(f"{label} must be in 1..2147483647")
    return result


def lexical_exists(path: pathlib.Path) -> bool:
    return os.path.lexists(os.fspath(path))


def publish_no_replace(source: pathlib.Path, destination: pathlib.Path) -> None:
    """Atomically publish source without replacing any destination."""
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        renameat2 = libc.renameat2
    except AttributeError as exc:
        raise OSError(errno.ENOSYS, "renameat2(RENAME_NOREPLACE) is unavailable") from exc
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    result = renameat2(
        AT_FDCWD,
        os.fsencode(source),
        AT_FDCWD,
        os.fsencode(destination),
        RENAME_NOREPLACE,
    )
    if result == 0:
        return
    error = ctypes.get_errno()
    if error == errno.EEXIST:
        raise FileExistsError(error, f"output path already exists: {destination}", os.fspath(destination))
    if error in (errno.ENOSYS, errno.EINVAL):
        raise OSError(error, "renameat2(RENAME_NOREPLACE) is unsupported on this platform")
    raise OSError(error, os.strerror(error), os.fspath(destination))


def load_inputs() -> tuple[dict[str, str], list[dict[str, Any]]]:
    data: dict[str, str] = {}
    items: list[dict[str, Any]] = []
    for index, relative in enumerate(PACKAGED_PATHS):
        source = ROOT / relative
        try:
            metadata = source.lstat()
        except FileNotFoundError as exc:
            raise ValueError(f"packaged input is missing: {relative}") from exc
        if stat.S_ISLNK(metadata.st_mode):
            fail(f"packaged input must not be a symlink: {relative}")
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"packaged input must be a regular file: {relative}")
        raw = source.read_bytes()
        if b"\0" in raw:
            fail(f"packaged input contains a NUL byte: {relative}")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError(f"packaged input is not UTF-8: {relative}") from exc
        key = f"file-{index:02d}"
        mode = 0o555 if relative in EXECUTABLE_PATHS else 0o444
        data[key] = text
        items.append({"key": key, "path": relative, "mode": mode})
    return data, items


def config_hash(data: dict[str, str], items: list[dict[str, Any]]) -> str:
    rows = []
    for item in sorted(items, key=lambda value: value["path"]):
        rows.append({
            "path": item["path"],
            "mode": item["mode"],
            "bytes_sha256": hashlib.sha256(data[item["key"]].encode("utf-8")).hexdigest(),
        })
    serialized = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(serialized).hexdigest()


def labels(component: str) -> dict[str, str]:
    return {
        "app.kubernetes.io/name": "hermes-software-poc",
        "app.kubernetes.io/component": component,
        "app.kubernetes.io/managed-by": "hermes-software-poc-renderer",
    }


def namespace_object() -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": NAMESPACE,
            "labels": {
                **labels("namespace"),
                "pod-security.kubernetes.io/enforce": "restricted",
                "pod-security.kubernetes.io/audit": "restricted",
                "pod-security.kubernetes.io/warn": "restricted",
            },
        },
    }


def configmap_object(name: str, data: dict[str, str]) -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": labels("files")},
        "immutable": True,
        "data": data,
    }


def pvc_object() -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "PersistentVolumeClaim",
        "metadata": {"name": PVC_NAME, "namespace": NAMESPACE, "labels": labels("data")},
        "spec": {
            "accessModes": ["ReadWriteOnce"],
            "resources": {"requests": {"storage": "2Gi"}},
        },
    }


def split_command(command: list[str]) -> tuple[list[str], list[str]]:
    if len(command) == 1:
        return command, []
    return command[:1], command[1:]


def job_object(
    *,
    name: str,
    image: str,
    read_only_software: bool,
    command: list[str],
    deadline: int,
    uid: int,
    gid: int,
    agent_digest: str,
    configmap_name: str,
    items: list[dict[str, Any]],
    webui: bool,
) -> dict[str, Any]:
    container_command, args = split_command(command)
    environment = [
        {"name": "HOME", "value": "/tmp"},
        {"name": "TMPDIR", "value": "/test-tmp"},
        {"name": "PATH", "value": "/opt/hermes/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
        {"name": "PYTHONDONTWRITEBYTECODE", "value": "1"},
        {"name": "PIP_CACHE_DIR", "value": "/test-tmp/pip-cache"},
        {"name": "XDG_CACHE_HOME", "value": "/test-tmp/xdg-cache"},
        {"name": "npm_config_cache", "value": "/test-tmp/npm-cache"},
        {"name": "npm_config_yes", "value": "true"},
        {"name": "SOFTWARE_ROOT", "value": "/software"},
        {"name": "EXPECTED_SOFTWARE_ROOT", "value": "/software"},
        {"name": "TEST_TMP", "value": "/test-tmp"},
        {"name": "TEST_SOURCE_DIGEST", "value": agent_digest},
    ]
    if webui:
        inherited = "/custom/image/lib:/custom/extension/lib"
        environment.extend([
            {"name": "LD_LIBRARY_PATH", "value": inherited},
            {"name": "EXPECTED_INHERITED_LD_LIBRARY_PATH", "value": inherited},
        ])
    pod_labels = labels(name.removeprefix("hermes-software-poc-"))
    software_mount: dict[str, Any] = {"name": "software", "mountPath": "/software"}
    if read_only_software:
        software_mount["readOnly"] = True
    container: dict[str, Any] = {
        "name": "verify",
        "image": image,
        "imagePullPolicy": "IfNotPresent",
        "command": container_command,
        "args": args,
        "env": environment,
        "securityContext": {
            "allowPrivilegeEscalation": False,
            "privileged": False,
            "readOnlyRootFilesystem": True,
            "runAsNonRoot": True,
            "runAsUser": uid,
            "runAsGroup": gid,
            "capabilities": {"drop": ["ALL"]},
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "resources": {
            "requests": {"cpu": "100m", "memory": "256Mi"},
            "limits": {"cpu": "1000m", "memory": "1Gi"},
        },
        "volumeMounts": [
            software_mount,
            {"name": "poc", "mountPath": "/poc", "readOnly": True},
            {"name": "tmp", "mountPath": "/tmp"},
            {"name": "test-tmp", "mountPath": "/test-tmp"},
        ],
    }
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": pod_labels},
        "spec": {
            "backoffLimit": 0,
            "activeDeadlineSeconds": deadline,
            "template": {
                "metadata": {"labels": pod_labels},
                "spec": {
                    "automountServiceAccountToken": False,
                    "restartPolicy": "Never",
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": uid,
                        "runAsGroup": gid,
                        "fsGroup": gid,
                        "fsGroupChangePolicy": "OnRootMismatch",
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "containers": [container],
                    "volumes": [
                        {"name": "software", "persistentVolumeClaim": {"claimName": PVC_NAME}},
                        {"name": "poc", "configMap": {
                            "name": configmap_name,
                            "defaultMode": 0o444,
                            "items": items,
                        }},
                        {"name": "tmp", "emptyDir": {"sizeLimit": "512Mi"}},
                        {"name": "test-tmp", "emptyDir": {"sizeLimit": "512Mi"}},
                    ],
                },
            },
        },
    }


def dump_yaml(path: pathlib.Path, obj: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = yaml.safe_dump(obj, sort_keys=False, default_flow_style=False)
    path.write_text(rendered, encoding="utf-8")


def render_package(output: pathlib.Path, agent_image: str, webui_image: str, uid: int, gid: int) -> None:
    agent_digest = validate_image(agent_image, "agent image")
    validate_image(webui_image, "webui image")
    if lexical_exists(output):
        fail(f"output path already exists: {output}")
    parent = output.parent
    if not parent.exists() or not parent.is_dir() or parent.is_symlink():
        fail(f"output parent must be an existing non-symlink directory: {parent}")
    data, items = load_inputs()
    suffix = config_hash(data, items)[:16]
    configmap_name = f"hermes-software-poc-files-{suffix}"
    temporary = pathlib.Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp-", dir=parent))
    published = False

    def stop(signum: int, _frame: Any) -> None:
        raise SystemExit(128 + signum)

    previous_handlers = {
        signum: signal.getsignal(signum)
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    }
    try:
        for signum in previous_handlers:
            signal.signal(signum, stop)
        dump_yaml(temporary / "00-namespace.yaml", namespace_object())
        dump_yaml(temporary / "01-configmap.yaml", configmap_object(configmap_name, data))
        dump_yaml(temporary / "02-pvc.yaml", pvc_object())
        images = {"agent": agent_image, "webui": webui_image}
        for relative, name, image_key, read_only, command, deadline in JOB_FILES:
            dump_yaml(
                temporary / relative,
                job_object(
                    name=name,
                    image=images[image_key],
                    read_only_software=read_only,
                    command=command,
                    deadline=deadline,
                    uid=uid,
                    gid=gid,
                    agent_digest=agent_digest,
                    configmap_name=configmap_name,
                    items=items,
                    webui=image_key == "webui",
                ),
            )
        publish_no_replace(temporary, output)
        published = True
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        if not published and lexical_exists(temporary):
            shutil.rmtree(temporary)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--agent-image", required=True)
    parser.add_argument("--webui-image", required=True)
    parser.add_argument("--uid", required=True)
    parser.add_argument("--gid", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        uid = validate_identity(args.uid, "uid")
        gid = validate_identity(args.gid, "gid")
        render_package(args.output, args.agent_image, args.webui_image, uid, gid)
    except (OSError, ValueError) as exc:
        print(f"render.py: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
