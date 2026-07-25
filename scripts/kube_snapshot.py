#!/usr/bin/env python3
"""Normalize repository-owned Kubernetes JSON into a portable recovery snapshot.

Purpose: Remove live-cluster metadata and keep only resources owned by this setup.
Usage: kube_snapshot.py snapshot RAW_DIR OUTPUT_JSON NAMESPACE; kube_snapshot.py split SNAPSHOT_JSON NAMESPACE_JSON RESOURCES_JSON
Requirements: Python 3 and JSON files produced by kubectl get -o json.
Exit status: 0 on success; non-zero on invalid or incomplete input.
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

RESOURCE_FILES = {
    "namespace": "namespace",
    "pvc": "pvc",
    "deployment": "deployment",
    "service": "service",
    "job": "job",
    "ingress": "ingress",
    "networkpolicy": "networkpolicy",
    "serviceaccount": "serviceaccount",
    "middleware": "middleware",
    "secret": "secret",
}
SECRET_NAMES = {
    "hermes-dashboard-auth",
    "hermes-api-server",
    "hermes-browser-token",
    "hermes-browser-cdp",
}
DROP_METADATA = {
    "creationTimestamp",
    "generation",
    "managedFields",
    "resourceVersion",
    "selfLink",
    "uid",
}


def clean(resource: dict) -> dict:
    result = copy.deepcopy(resource)
    metadata = result.get("metadata", {})
    for key in DROP_METADATA:
        metadata.pop(key, None)
    result.pop("status", None)
    return result


def items_from_raw(path: Path) -> list[dict]:
    if not path.exists() or path.stat().st_size == 0:
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("kind") == "List":
        return data.get("items", [])
    return [data]


def snapshot(raw_dir: Path, output: Path, namespace: str) -> None:
    items: list[dict] = []
    for filename, kind_name in RESOURCE_FILES.items():
        for resource in items_from_raw(raw_dir / f"{filename}.json"):
            metadata = resource.get("metadata", {})
            name = metadata.get("name", "")
            if kind_name != "namespace" and not metadata.get("namespace") == namespace:
                continue
            if kind_name == "secret":
                if name not in SECRET_NAMES:
                    continue
            elif kind_name != "namespace" and not name.startswith("hermes-"):
                continue
            items.append(clean(resource))
    if not any(item.get("kind") == "Namespace" for item in items):
        raise SystemExit("Kubernetes snapshot is missing the target Namespace")
    items.sort(key=lambda item: (item.get("kind", ""), item.get("metadata", {}).get("name", "")))
    output.write_text(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}, indent=2) + "\n", encoding="utf-8")


def split(snapshot_path: Path, namespace_path: Path, resources_path: Path) -> None:
    data = json.loads(snapshot_path.read_text(encoding="utf-8"))
    items = data.get("items", [])
    namespaces = [item for item in items if item.get("kind") == "Namespace"]
    if len(namespaces) != 1:
        raise SystemExit("Kubernetes snapshot must contain exactly one Namespace")
    resources = [item for item in items if item.get("kind") != "Namespace"]
    namespace_path.write_text(json.dumps(namespaces[0], indent=2) + "\n", encoding="utf-8")
    resources_path.write_text(json.dumps({"apiVersion": "v1", "kind": "List", "items": resources}, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("usage: kube_snapshot.py snapshot|split ...")
    if sys.argv[1] == "snapshot" and len(sys.argv) == 5:
        snapshot(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
        return 0
    if sys.argv[1] == "split" and len(sys.argv) == 5:
        split(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]))
        return 0
    raise SystemExit("usage: kube_snapshot.py snapshot RAW_DIR OUTPUT_JSON NAMESPACE | split SNAPSHOT_JSON NAMESPACE_JSON RESOURCES_JSON")


if __name__ == "__main__":
    raise SystemExit(main())
