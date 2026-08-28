# Immutable software generations PoC

This credential-free PoC separates software into three operational classes:

1. **Immutable image software** — OS packages, shared libraries, compilers, GPU runtimes, and privileged tooling belong in reviewed, scanned, digest-pinned container images.
2. **Managed software generations** — portable Python packages and the Node/npm/npx runtime live in content-addressed generations on persistent storage.
3. **Workspace experiments** — temporary, user-owned experiments belong in the workspace and are never treated as managed production dependencies.

## Generation model

`python/` and `node/` each contain immutable `generations/<hash>/` directories plus relative `current` and `previous` symlinks. A component-local `flock` serializes reconciliation. A generation is usable only after validation and creation of `.complete`; link activation uses atomic rename, while rollback exchanges `current` and `previous` atomically with Linux `renameat2(RENAME_EXCHANGE)`.

Python declarations are hash-locked requirements files owned by the installer/operator. Python virtual environments are location-bound, so they are constructed directly at their final content-addressed path; they are never built under a temporary path and moved. Exact installed package names and versions must match the lock declaration.

Node generations copy one immutable Agent-image Node ELF, the complete npm tree, optional resolved `libatomic.so.1`, and installer-owned wrappers. The Node wrapper prepends only its generation-private library directory while preserving an inherited `LD_LIBRARY_PATH` without duplication. npm and npx invoke the generation-local Node wrapper directly, so a hostile earlier `PATH` entry cannot redirect them.

Hermes consumers should prepend stable paths such as:

```text
/software/python/current/bin:/software/node/current/bin
```

They should not depend on individual generation hashes.

## Security and ownership boundary

The harness runs unprivileged, uses no Kubernetes API token, Secret, Service, Ingress, or RBAC, and never installs host packages. Declarations and image digests are operator-reviewed inputs; skill `required_commands` metadata is readiness information, not installation authorization. Invalid locks, corrupt complete generations, incomplete generations, and malformed rollback links fail closed without moving active links.

This PoC does not make arbitrary Agent-image binaries portable across incompatible architectures, libc families, or WebUI images. The WebUI compatibility test executes Node/npm/npx only; Python is checked as metadata because an Agent-built Python venv is not assumed ABI-compatible with an arbitrary WebUI image.

## QA deployment

The QA harness uses an isolated `qa` namespace, one 2 GiB PVC, one immutable ConfigMap, and sequential completed Jobs using digest-pinned Agent and WebUI images. It validates lifecycle, persistence across Pods, exact removal semantics, idempotency, invalid-lock failure safety, atomic rollback, hostile-PATH isolation, and inherited loader preservation.

The retained QA namespace can be removed when inspection is complete:

```bash
sudo k3s kubectl delete namespace qa --wait=true
```

Production installer manifests remain unchanged; this directory is a PoC and does not by itself resolve issue #98.
