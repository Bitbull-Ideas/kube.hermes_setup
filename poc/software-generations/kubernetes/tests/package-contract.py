#!/usr/bin/env python3
"""Contract test for the isolated QA Kubernetes package."""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
KUBE = ROOT / "kubernetes"
RENDER = KUBE / "render.py"
AGENT = "registry.example.com/hermes-agent@sha256:" + "1" * 64
WEBUI = "registry.example.com/hermes-webui@sha256:" + "2" * 64
AGENT_DIGEST = "sha256:" + "1" * 64
EXPECTED_FILES = {
    "00-namespace.yaml",
    "01-configmap.yaml",
    "02-pvc.yaml",
    "jobs/10-lifecycle.yaml",
    "jobs/20-persist.yaml",
    "jobs/30-idempotency.yaml",
    "jobs/40-invalid-lock.yaml",
    "jobs/50-rollback.yaml",
    "jobs/60-webui.yaml",
    "jobs/70-final-verify.yaml",
}
JOB_CONTRACT = {
    "hermes-software-poc-lifecycle": (AGENT, False, ["/bin/bash", "/poc/kubernetes/entrypoints/lifecycle.sh"]),
    "hermes-software-poc-persist": (AGENT, True, ["/opt/hermes/.venv/bin/python", "/poc/verify-state.py"]),
    "hermes-software-poc-idempotency": (AGENT, False, ["/bin/bash", "/poc/kubernetes/entrypoints/idempotency.sh"]),
    "hermes-software-poc-invalid-lock": (AGENT, False, ["/bin/bash", "/poc/kubernetes/entrypoints/invalid-lock.sh"]),
    "hermes-software-poc-rollback": (AGENT, False, ["/bin/bash", "/poc/tests/rollback-cycle.sh"]),
    "hermes-software-poc-webui": (WEBUI, True, ["/software/node/current/bin/node", "/poc/verify-webui-state.js"]),
    "hermes-software-poc-final-verify": (AGENT, True, ["/opt/hermes/.venv/bin/python", "/poc/verify-state.py"]),
}
FORBIDDEN_KINDS = {
    "Secret", "Service", "Ingress", "Role", "RoleBinding", "ClusterRole",
    "ClusterRoleBinding", "ServiceAccount", "NetworkPolicy", "Deployment",
    "DaemonSet", "StatefulSet",
}
PRIVATE_RE = re.compile(
    os.environ.get("PRIVATE_HOST_REGEX", r"(?:internal[.]example|private[.]invalid)"),
    re.I,
)
DIGEST_RE = re.compile(r"^\S+@sha256:[0-9a-f]{64}$")
CM_NAME_RE = re.compile(r"^hermes-software-poc-files-([0-9a-f]{16})$")
EXECUTABLE_PATHS = {
    "python/reconcile.sh", "node/reconcile.sh", "rollback-generation.sh",
    "tests/lifecycle.sh", "tests/idempotency.sh", "tests/locked-failure.sh",
    "tests/rollback-cycle.sh", "verify-state.py", "verify-webui-state.js",
    "kubernetes/entrypoints/lifecycle.sh", "kubernetes/entrypoints/idempotency.sh",
    "kubernetes/entrypoints/invalid-lock.sh",
}
DATA_PATHS = {"requirements-a.lock", "requirements-b.lock", "requirements-bad.lock"}
EXPECTED_PACKAGED_PATHS = EXECUTABLE_PATHS | DATA_PATHS


def directory_digest(root: pathlib.Path) -> str:
    rows = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        rows.append((rel, stat.S_IMODE(path.stat().st_mode), hashlib.sha256(path.read_bytes()).hexdigest()))
    return hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()


def load_one(path: pathlib.Path) -> dict:
    docs = list(yaml.safe_load_all(path.read_text()))
    assert len(docs) == 1 and isinstance(docs[0], dict), path
    return docs[0]


def env_map(container: dict) -> dict[str, str]:
    result = {}
    for item in container.get("env", []):
        assert set(item) == {"name", "value"}, item
        assert item["name"] not in result
        result[item["name"]] = item["value"]
    return result


def assert_container(container: dict, *, expected_image: str, read_only_software: bool, command: list[str]) -> None:
    assert container.get("image") == expected_image
    assert DIGEST_RE.fullmatch(container["image"])
    assert container.get("imagePullPolicy") == "IfNotPresent"
    assert container.get("command", []) + container.get("args", []) == command
    security = container.get("securityContext", {})
    assert security.get("allowPrivilegeEscalation") is False
    assert security.get("privileged") is not True
    assert security.get("readOnlyRootFilesystem") is True
    assert security.get("runAsNonRoot") is True
    assert security.get("runAsUser") == 10000
    assert security.get("runAsGroup") == 10000
    assert security.get("capabilities", {}).get("drop") == ["ALL"]
    assert security.get("seccompProfile", {}).get("type") == "RuntimeDefault"
    resources = container.get("resources", {})
    for side in ("requests", "limits"):
        assert resources.get(side, {}).get("cpu")
        assert resources.get(side, {}).get("memory")
    mounts = {m["name"]: m for m in container.get("volumeMounts", [])}
    assert set(mounts) == {"software", "poc", "tmp", "test-tmp"}
    assert mounts["software"]["mountPath"] == "/software"
    assert mounts["software"].get("readOnly", False) is read_only_software
    assert mounts["poc"] == {"name": "poc", "mountPath": "/poc", "readOnly": True}
    assert mounts["tmp"]["mountPath"] == "/tmp"
    assert mounts["test-tmp"]["mountPath"] == "/test-tmp"
    env = env_map(container)
    assert env["HOME"] == "/tmp"
    assert env["TMPDIR"] == "/test-tmp"
    assert env["PATH"] == (
        "/opt/hermes/.venv/bin:/usr/local/sbin:/usr/local/bin:"
        "/usr/sbin:/usr/bin:/sbin:/bin"
    )
    assert env["PYTHONDONTWRITEBYTECODE"] == "1"
    assert env["PIP_CACHE_DIR"] == "/test-tmp/pip-cache"
    assert env["XDG_CACHE_HOME"] == "/test-tmp/xdg-cache"
    assert env["npm_config_cache"] == "/test-tmp/npm-cache"
    assert env["npm_config_yes"] == "true"
    assert env["SOFTWARE_ROOT"] == "/software"
    assert env["EXPECTED_SOFTWARE_ROOT"] == "/software"
    assert env["TEST_TMP"] == "/test-tmp"
    assert env["TEST_SOURCE_DIGEST"] == AGENT_DIGEST
    if expected_image == WEBUI:
        assert env["LD_LIBRARY_PATH"] == "/custom/image/lib:/custom/extension/lib"
        assert env["EXPECTED_INHERITED_LD_LIBRARY_PATH"] == env["LD_LIBRARY_PATH"]
    else:
        assert "EXPECTED_INHERITED_LD_LIBRARY_PATH" not in env


def packaged_content_hash(configmap: dict, items: list[dict]) -> str:
    data = configmap["data"]
    rows = []
    for item in sorted(items, key=lambda x: x["path"]):
        rows.append({
            "path": item["path"],
            "mode": item["mode"],
            "bytes_sha256": hashlib.sha256(data[item["key"]].encode()).hexdigest(),
        })
    return hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def render(output: pathlib.Path) -> None:
    subprocess.run([
        sys.executable, str(RENDER), "--output", str(output),
        "--agent-image", AGENT, "--webui-image", WEBUI,
        "--uid", "10000", "--gid", "10000",
    ], check=True)


def render_fails(output: pathlib.Path, *, agent: str = AGENT, webui: str = WEBUI,
                 uid: str = "10000", gid: str = "10000") -> None:
    result = subprocess.run([
        sys.executable, str(RENDER), "--output", str(output),
        "--agent-image", agent, "--webui-image", webui,
        "--uid", uid, "--gid", gid,
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode != 0, (output, result.stdout, result.stderr)


def main() -> None:
    assert RENDER.is_file(), f"renderer missing: {RENDER}"
    with tempfile.TemporaryDirectory(prefix="hermes-kube-package-test.") as temp:
        first = pathlib.Path(temp) / "first"
        second = pathlib.Path(temp) / "second"
        render(first)
        render(second)
        actual = {p.relative_to(first).as_posix() for p in first.rglob("*.yaml")}
        assert actual == EXPECTED_FILES, (actual, EXPECTED_FILES)
        assert directory_digest(first) == directory_digest(second)
        for rel in EXPECTED_FILES:
            assert (first / rel).read_bytes() == (second / rel).read_bytes(), rel

        # Invalid inputs fail before publishing any manifest output.
        for label, kwargs in (
            ("agent-tag", {"agent": "registry.example.com/hermes-agent:latest"}),
            ("agent-digest", {"agent": "registry.example.com/hermes-agent@sha256:bad"}),
            ("agent-uppercase", {"agent": "registry.example.com/hermes-agent@sha256:" + "A" * 64}),
            ("agent-whitespace", {"agent": "registry.example.com/hermes agent@sha256:" + "1" * 64}),
            ("agent-double-at", {"agent": "registry.example.com@team/hermes-agent@sha256:" + "1" * 64}),
            ("webui-tag", {"webui": "registry.example.com/hermes-webui:latest"}),
            ("webui-digest", {"webui": "registry.example.com/hermes-webui@sha256:bad"}),
            ("webui-uppercase", {"webui": "registry.example.com/hermes-webui@sha256:" + "A" * 64}),
            ("webui-whitespace", {"webui": "registry.example.com/hermes webui@sha256:" + "2" * 64}),
            ("uid-zero", {"uid": "0"}),
            ("uid-negative", {"uid": "-1"}),
            ("uid-text", {"uid": "user"}),
            ("uid-large", {"uid": "2147483648"}),
            ("gid-zero", {"gid": "0"}),
            ("gid-negative", {"gid": "-1"}),
            ("gid-text", {"gid": "group"}),
            ("gid-large", {"gid": "2147483648"}),
        ):
            destination = pathlib.Path(temp) / f"reject-{label}"
            render_fails(destination, **kwargs)
            assert not destination.exists(), destination
        nonempty = pathlib.Path(temp) / "nonempty"
        nonempty.mkdir()
        (nonempty / "owned-by-operator").write_text("preserve\n")
        render_fails(nonempty)
        assert (nonempty / "owned-by-operator").read_text() == "preserve\n"
        symlink = pathlib.Path(temp) / "symlink-output"
        symlink.symlink_to(nonempty, target_is_directory=True)
        render_fails(symlink)
        assert symlink.is_symlink()
        output_file = pathlib.Path(temp) / "output-file"
        output_file.write_text("preserve\n")
        render_fails(output_file)
        assert output_file.read_text() == "preserve\n"

        objects = [(p, load_one(p)) for p in sorted(first.rglob("*.yaml"))]
        kinds = [obj.get("kind") for _, obj in objects]
        assert not (set(kinds) & FORBIDDEN_KINDS)
        assert kinds.count("Namespace") == 1
        assert kinds.count("ConfigMap") == 1
        assert kinds.count("PersistentVolumeClaim") == 1
        assert kinds.count("Job") == 7

        cm_obj = next(obj for _, obj in objects if obj["kind"] == "ConfigMap")
        cm_name = cm_obj["metadata"]["name"]
        match = CM_NAME_RE.fullmatch(cm_name)
        assert match, cm_name
        assert cm_obj.get("immutable") is True
        assert len(json.dumps(cm_obj, sort_keys=True, separators=(",", ":")).encode()) < 900 * 1024

        jobs = set()
        for path, obj in objects:
            text = path.read_text()
            assert not PRIVATE_RE.search(text), path
            kind = obj["kind"]
            metadata = obj.get("metadata", {})
            name = metadata.get("name", "")
            if kind == "Namespace":
                assert name == "qa"
                labels = metadata.get("labels", {})
                assert labels.get("pod-security.kubernetes.io/enforce") == "restricted"
                assert labels.get("pod-security.kubernetes.io/audit") == "restricted"
                assert labels.get("pod-security.kubernetes.io/warn") == "restricted"
                continue
            assert metadata.get("namespace") == "qa", (path, metadata)
            assert name.startswith("hermes-software-poc-"), name
            if kind == "PersistentVolumeClaim":
                assert obj["spec"]["accessModes"] == ["ReadWriteOnce"]
                assert obj["spec"]["resources"]["requests"]["storage"] == "2Gi"
            elif kind == "Job":
                jobs.add(name)
                expected_image, read_only_software, command = JOB_CONTRACT[name]
                spec = obj["spec"]
                assert spec.get("backoffLimit") == 0
                assert "ttlSecondsAfterFinished" not in spec
                deadline = spec.get("activeDeadlineSeconds")
                assert isinstance(deadline, int) and 60 <= deadline <= 1800
                pod = spec["template"]["spec"]
                assert pod.get("automountServiceAccountToken") is False
                assert pod.get("restartPolicy") == "Never"
                assert not any(pod.get(key) for key in ("hostNetwork", "hostPID", "hostIPC", "shareProcessNamespace"))
                pod_security = pod.get("securityContext", {})
                assert pod_security.get("runAsNonRoot") is True
                assert pod_security.get("runAsUser") == 10000
                assert pod_security.get("runAsGroup") == 10000
                assert pod_security.get("fsGroup") == 10000
                assert pod_security.get("fsGroupChangePolicy") == "OnRootMismatch"
                assert pod_security.get("seccompProfile", {}).get("type") == "RuntimeDefault"
                volumes = {v["name"]: v for v in pod.get("volumes", [])}
                assert set(volumes) == {"software", "poc", "tmp", "test-tmp"}
                assert volumes["software"]["persistentVolumeClaim"]["claimName"] == "hermes-software-poc-data"
                cm_volume = volumes["poc"]["configMap"]
                assert cm_volume["name"] == cm_name
                assert cm_volume.get("defaultMode") == 0o444
                items = cm_volume.get("items", [])
                assert len(items) == len(EXPECTED_PACKAGED_PATHS)
                assert {item["path"] for item in items} == EXPECTED_PACKAGED_PATHS
                assert all(not pathlib.PurePosixPath(item["path"]).is_absolute() for item in items)
                assert all(".." not in pathlib.PurePosixPath(item["path"]).parts for item in items)
                assert all(item["mode"] == (0o555 if item["path"] in EXECUTABLE_PATHS else 0o444) for item in items)
                for scratch in ("tmp", "test-tmp"):
                    empty = volumes[scratch]["emptyDir"]
                    assert empty.get("sizeLimit") == "512Mi"
                assert len(pod.get("containers", [])) == 1
                assert not pod.get("initContainers")
                assert not pod.get("serviceAccountName")
                assert not any("hostPath" in v for v in volumes.values())
                assert_container(pod["containers"][0], expected_image=expected_image,
                                 read_only_software=read_only_software, command=command)
        assert jobs == set(JOB_CONTRACT)

        sample_job = next(obj for _, obj in objects if obj.get("kind") == "Job")
        volumes = {v["name"]: v for v in sample_job["spec"]["template"]["spec"]["volumes"]}
        items = volumes["poc"]["configMap"]["items"]
        expected_hash = packaged_content_hash(cm_obj, items)
        assert match.group(1) == expected_hash[:16]
        keys = [item["key"] for item in items]
        assert len(keys) == len(set(keys))
        assert set(keys) == set(cm_obj["data"])
        assert all(re.fullmatch(r"[A-Za-z0-9._-]+", key) for key in keys)
        webui_js = ROOT / "verify-webui-state.js"
        assert webui_js.is_file()
        assert webui_js.read_text().startswith("#!/usr/bin/env node\n'use strict';\n")
        webui_job = next(obj for _, obj in objects if obj.get("metadata", {}).get("name") == "hermes-software-poc-webui")
        webui_container = webui_job["spec"]["template"]["spec"]["containers"][0]
        execution = webui_container.get("command", []) + webui_container.get("args", [])
        assert execution == ["/software/node/current/bin/node", "/poc/verify-webui-state.js"]
        assert not any(re.search(r"(^|/)(?:python|python3)$|verify-state[.]py", value, re.I) for value in execution)
        js_text = webui_js.read_text()
        binding = re.findall(
            r"const\s*\{([^}]*)\}\s*=\s*require\(\s*['\"]node:child_process['\"]\s*\)",
            js_text,
        )
        assert len(binding) == 1, binding
        imported = {name.strip() for name in binding[0].split(",") if name.strip()}
        assert imported == {"spawnSync"}, imported
        assert not re.search(r"child_process\s*[.](?:exec|execSync|execFile|execFileSync)\b", js_text)
        assert not re.search(r"\bshell\s*:\s*true\b", js_text)
        allowed_targets = {
            "/software/node/current/bin/node",
            "/software/node/current/bin/npm",
            "/software/node/current/bin/npx",
        }
        spawn_targets = re.findall(r"\bspawnSync\s*\(\s*(['\"])(/[^'\"]+)\1\s*,", js_text)
        spawn_count = len(re.findall(r"\bspawnSync\s*\(", js_text))
        extracted = [target for _, target in spawn_targets]
        assert spawn_count == len(extracted), (spawn_count, extracted)
        assert set(extracted) == allowed_targets, extracted
        assert not any(re.search(r"(?:^|/)(?:python[0-9.]*|(?:ba)?sh)$", target, re.I) for target in extracted)
        entrypoint_contract = {
            ROOT / "kubernetes/entrypoints/lifecycle.sh": (
                'PYTHON_BIN=/opt/hermes/.venv/bin/python',
                'NODE_SRC=/usr/local/bin/node',
                'NPM_SRC=/usr/local/lib/node_modules/npm',
                'cp -L /poc/requirements-a.lock /test-tmp/requirements-a.lock',
                'cp -L /poc/requirements-b.lock /test-tmp/requirements-b.lock',
                'cp -L /poc/requirements-bad.lock /test-tmp/requirements-bad.lock',
                'REQUIREMENTS_A=/test-tmp/requirements-a.lock',
                'REQUIREMENTS_B=/test-tmp/requirements-b.lock',
                'REQUIREMENTS_BAD=/test-tmp/requirements-bad.lock',
            ),
            ROOT / "kubernetes/entrypoints/idempotency.sh": (
                'PYTHON_BIN=/opt/hermes/.venv/bin/python',
                'NODE_SRC=/usr/local/bin/node',
                'NPM_SRC=/usr/local/lib/node_modules/npm',
                'cp -L /poc/requirements-a.lock /test-tmp/requirements-a.lock',
                'REQUIREMENTS_A=/test-tmp/requirements-a.lock',
            ),
            ROOT / "kubernetes/entrypoints/invalid-lock.sh": (
                'PYTHON_BIN=/opt/hermes/.venv/bin/python',
                'cp -L /poc/requirements-bad.lock /test-tmp/requirements-bad.lock',
                'REQUIREMENTS_BAD=/test-tmp/requirements-bad.lock',
            ),
        }
        for script, required in entrypoint_contract.items():
            text = script.read_text()
            assert "command -v" not in text
            assert "readlink -f" not in text
            for value in required:
                assert value in text, (script, value)
        print("Kubernetes package contract passed")


if __name__ == "__main__":
    main()
