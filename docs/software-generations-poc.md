# Immutable software generations PoC

## Status and scope

This directory documents and exercises an **experimental, opt-in proof of concept** under [`poc/software-generations/`](../poc/software-generations/). The normal `configure.sh` and `install.sh` paths do not enable it, and the PoC does not modify an existing Hermes installation unless an operator deliberately renders and applies its isolated QA package.

The PoC separates software into three classes:

| Class | Examples | Supported ownership model |
|---|---|---|
| Immutable image software | OS packages, shared libraries, compilers, GPU runtimes | Build and scan a digest-pinned custom container image |
| Managed portable software | Hash-locked Python packages, Node/npm/npx runtime | Content-addressed generations on persistent storage |
| Workspace experiments | Temporary project tools and one-off tests | User-owned workspace sandbox; never production state |

Do not persist `/usr`, `/lib`, `/etc`, or an OS package database on a PVC. Do not grant Hermes root, a container-runtime socket, or Kubernetes credentials to install software.

## Generation layout

Each managed component has immutable generations and two stable relative links:

```text
/software/
├── python/
│   ├── generations/<sha256>/
│   ├── current -> generations/<sha256>
│   └── previous -> generations/<sha256>
└── node/
    ├── generations/<sha256>/
    ├── current -> generations/<sha256>
    └── previous -> generations/<sha256>
```

A component-local `flock` serializes reconciliation. A generation becomes selectable only after its payload, metadata, package inventory, wrappers, and health commands pass validation and `.complete` is written. Activation uses atomic symlink replacement. Rollback validates both targets and exchanges `current` and `previous` atomically with Linux `renameat2(RENAME_EXCHANGE)`.

Python virtual environments are location-bound, so they are created directly at their final content-addressed path. The input requirements file uses exact versions and `--hash` entries; the installed inventory must match exactly. Removing a declaration therefore produces a fresh generation without the removed package rather than leaving stale transitive state.

Node generations contain one Agent-image Node ELF, the complete npm tree, installer-owned `node`/`npm`/`npx` wrappers, and `libatomic.so.1` only when the source ELF resolves it. npm and npx invoke the generation-local Node wrapper directly, so an earlier hostile `PATH` entry cannot redirect them.

## Hermes integration contract

Consumers should use stable paths, never individual generation hashes:

```text
/software/python/current/bin:/software/node/current/bin
```

Skills may declare `required_commands` for readiness reporting, but skill metadata is not installation authorization. Durable installation remains an operator-reviewed action against pinned declarations and image digests.

The PoC does not assume an Agent-built Python environment is ABI-compatible with an arbitrary WebUI image. The cross-image verifier therefore treats Python generations as metadata and executes only Node/npm/npx from WebUI.

## Relationship to issue #98

Issue #98 concerns the WebUI Deployment replacing a custom image's own `LD_LIBRARY_PATH` with the directory required by the copied Node ELF.

The PoC's Node wrapper is the candidate solution:

1. The WebUI container keeps its image-defined loader environment.
2. Only the Node process prepends its generation-private library directory.
3. An inherited loader path is preserved in order and the private directory is not duplicated.
4. npm and npx use that wrapper without replacing the WebUI image entrypoint.

The PoC alone does **not** close issue #98. This v2.7.0 candidate branch also integrates the wrapper into `manifests/hermes.yaml.tpl`, removes the WebUI-global loader override, and adds production-render regression coverage. Issue #98 can be closed only after the production-rendered WebUI init path passes live validation with a custom inherited loader value; until then the fix remains a release blocker rather than a completed claim.

## QA package

The renderer creates an isolated QA package containing:

- restricted `qa` Namespace;
- one content-addressed immutable ConfigMap;
- one 2 GiB `ReadWriteOnce` PVC;
- seven sequential Jobs using digest-pinned Agent and WebUI images;
- no Secret, Service, Ingress, RBAC, ServiceAccount, or Kubernetes API token mount.

Render to a new directory:

```bash
python3 poc/software-generations/kubernetes/render.py \
  --output /tmp/hermes-software-qa \
  --agent-image registry.example.com/hermes-agent@sha256:<64-lowercase-hex> \
  --webui-image registry.example.com/hermes-webui@sha256:<64-lowercase-hex> \
  --uid 10000 \
  --gid 10000
```

The renderer refuses tags, malformed digests, root IDs, symlink destinations, files, and existing directories. It publishes atomically with `renameat2(RENAME_NOREPLACE)` so a concurrent operator-created destination is never replaced.

The intended live sequence is:

1. lifecycle build;
2. independent Pod persistence check;
3. unchanged idempotency check;
4. invalid-lock failure-safety check;
5. two-way rollback and restore;
6. WebUI Node-loader compatibility check;
7. final independent state verification.

Server-side dry-run or local tests are not live acceptance evidence. Record Job status, Pod exit/restart state, logs, Warning Events, PVC identity, and cleanup for every live run.

## Cleanup

Return the QA Namespace to an empty retained state:

```bash
kubectl -n qa delete job -l app.kubernetes.io/name=hermes-software-poc --wait=true
kubectl -n qa delete configmap -l app.kubernetes.io/name=hermes-software-poc --wait=true
kubectl -n qa delete pvc hermes-software-poc-data --wait=true
```

Remove the complete disposable namespace only when no follow-up inspection is needed:

```bash
kubectl delete namespace qa --wait=true
```

Never run those commands against a production namespace.
