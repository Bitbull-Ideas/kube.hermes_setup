# Software generation PoC design notes

## Python virtual environments are location-bound

The first local lifecycle attempt built a Python virtual environment under a temporary staging path and then intended to move it into `python/generations/<hash>`.

The test failed before publication because generated console scripts such as `pip3` embedded the staging interpreter path:

```text
<temporary-root>/python/staging/<generation>.<pid>/bin/python
```

Python virtual environments also record absolute locations in activation files and `pyvenv.cfg`. Relocating a completed venv is therefore not a sound activation mechanism.

The corrected model is:

1. Compute the generation identity before creating it.
2. Hold the Python component lock.
3. Build directly at `python/generations/<hash>` using `venv --copies`.
4. Install from a hash-locked requirements file with `--require-hashes --no-deps`.
5. Validate final-path scripts, configuration, exact package inventory, and metadata.
6. Write `.complete` last.
7. Atomically update `current` only after complete validation.
8. On failure, remove only the incomplete generation created by that invocation.

Node generations remain staged because the copied ELF, npm tree, and generated wrappers are relocatable.

No Kubernetes resource had been changed when this finding was discovered; the `qa` namespace was still absent.

## Lifecycle harness declaration-order failure

The focused reconciler fail-closed tests passed. The subsequent broad lifecycle run stopped in the test-only `atomic_link` helper before Node generation work began. With `set -u`, Bash expands initializers in a combined `local` command before sibling assignments are available, so `tmp="${link}.test.$$"` referenced an unset `link`.

The helper now declares `target`, `link`, and dependent `tmp` separately, and mutable assertion state is function-local. This was a test-harness defect, not a generation architecture failure. No Kubernetes mutation occurred and the `qa` namespace remained absent.
