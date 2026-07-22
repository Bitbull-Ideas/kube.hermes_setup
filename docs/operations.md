# Operations guide

## Status

```bash
./maintain.sh status
./doctor.sh
```

## Restart

```bash
./maintain.sh restart
```

## Upgrade

Pin image tags in `hermes.env`, then run:

```bash
./install.sh
./doctor.sh
```

`install.sh` is re-runnable. It recreates the one-shot `hermes-init-config` Job before applying the manifest so Kubernetes Job immutability does not break upgrades/retries.

For a pull-latest style restart:

```bash
./maintain.sh upgrade
```

## Backup

```bash
mkdir -p backups
./maintain.sh backup ./backups/hermes-$(date -u +%Y%m%dT%H%M%SZ).tgz
```

The archive contains:

```text
/opt/data
/workspace
```

This includes OAuth state, sessions, skills, memories, workspace files, and WebUI state. Treat backups as sensitive. Restore replaces both visible and hidden entries on both PVCs, then reapplies `HERMES_RUNTIME_UID:HERMES_RUNTIME_GID` ownership from the active configuration.

## Restore

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.tgz
./doctor.sh
```


## Bootstrap agent configuration

The recommended configuration lifecycle is:

```bash
./setup.sh
# Later, after git pull:
./setup.sh --from-answers
```

`current_config/` is wizard-owned and contains the composed bootstrap, `hermes.env`, and installer artifacts. Replay safely replaces this directory only when its ownership marker is present. The wizard writes the Agent-native configuration to `current_config/bootstrap/config.yaml`; the installer injects it as `/opt/data/config.yaml` on the persistent `hermes-home` PVC, so a Pod restart preserves it. The root-level `configuration_answers` file preserves all answers, including secret-bearing answers, with mode `0600`. Both paths are Git-ignored. Bootstrap mode `missing` seeds absent PVC files and preserves later edits; `overwrite` replaces bootstrap-managed files on the next installer run.

The operational scripts resolve configuration in this order: an explicit `ENV_FILE`, root `hermes.env` when it exists, then wizard-generated `current_config/hermes.env`. Therefore bare `./doctor.sh` and `./maintain.sh` commands work after the wizard while preserving compatibility with manual root configuration.

## Initial generated credentials

When the wizard password prompt is left empty, the password is not generated until `install.sh` runs. It is therefore intentionally absent from `hermes.env` and `configuration_answers`. The installer writes all generated and applied initial values to:

```text
current_config/artifacts/generated-credentials.txt
```

The path follows `HERMES_RENDER_DIR`; manual installations default to `.rendered/generated-credentials.txt`. The directory is mode `0700` and the file is mode `0600`. The file contains `DASHBOARD_AUTH_USER`, `DASHBOARD_AUTH_PASSWORD`, `API_SERVER_KEY`, and `BROWSER_TOKEN`; values for disabled components may be empty.

Every installer run generates a new value for each still-empty secret variable, applies it to Kubernetes, and overwrites the capture file with the current applied values. Save required values in a password manager. If the local file was deleted, an authorized operator can recover the Dashboard/WebUI password from `secret/hermes-dashboard-auth`; avoid printing or sharing it except in a private terminal.

Use `HERMES_BOOTSTRAP_DIR` to seed SOUL, memory, skills, plugins, cron jobs, config, and workspace context into the persistent PVCs. This is useful for repeatable installations where the Agent should start with known behavior.

```bash
# Use a profile to bootstrap SOUL, memory, selected skills, requirements, and workspace
# (personal-assistant is the default)
echo 'HERMES_BOOTSTRAP_PROFILE=universal-system-architect' >> hermes.env
./install.sh
```

```bash
# Or build a fully custom bootstrap directory from shared + profile:
cp -a examples/bootstrap-shared ./bootstrap
cp -a examples/bootstrap-profiles/personal-assistant/. ./bootstrap/
$EDITOR ./bootstrap/*
cat >> hermes.env <<'EOF'
HERMES_BOOTSTRAP_DIR=./bootstrap
HERMES_BOOTSTRAP_MODE=missing
HERMES_BOOTSTRAP_INCLUDE_AUTH=false
EOF
./install.sh
```

The profile workflow uses one canonical shared skill source plus `skills.txt` selection. Profile defaults from `defaults.conf` are applied only when the operator has not set the corresponding variable. For generated profile composition, `HERMES_ANSIBLE_SETUP=false` excludes the profile's `workspace/ansible` tree as well as disabling Ansible initialization. This is non-destructive: it does not remove files already stored on a workspace PVC, and it does not filter an operator-owned custom `HERMES_BOOTSTRAP_DIR`.

Mapping:

```text
SOUL.md                  -> /opt/data/SOUL.md
memories/USER.md         -> /opt/data/memories/USER.md
memories/MEMORY.md       -> /opt/data/memories/MEMORY.md
skills/                  -> /opt/data/skills/
plugins/                 -> /opt/data/plugins/
cron/                    -> /opt/data/cron/
config.yaml              -> /opt/data/config.yaml
.env                     -> /opt/data/.env
workspace/               -> /workspace/
auth.json                -> /opt/data/auth.json only with HERMES_BOOTSTRAP_INCLUDE_AUTH=true
```

Use `HERMES_BOOTSTRAP_MODE=missing` for normal installs/upgrades. Use `overwrite` only when you intentionally want the bootstrap source to replace existing files. Bootstrap data, `current_config/`, and `configuration_answers` can contain personal data or credentials; keep them out of Git.

## Password rotation

`maintain.sh rotate-passwords` rotates the shared password for the enabled Dashboard and/or WebUI components and supports three explicit input modes:

1. **Interactive hidden prompts** with `--prompt` — default when stdin is a TTY.
2. **Generated value** with `--generate` — writes the new random value to `$HERMES_RENDER_DIR/rotated-credentials-*.txt`.
3. **Environment variables** with `--from-env` — intended for automation/CI.

Important: interactive rotation does **not** silently reuse password values from `hermes.env`. If a password is present in the env file and you want to apply exactly that value, say so explicitly with `--from-env`.

Interactive rotation:

```bash
./maintain.sh rotate-passwords --prompt
```

Dashboard + WebUI, lab password allowed:

```bash
./maintain.sh rotate-passwords --lab --prompt
```

Generate a new random value:

```bash
./maintain.sh rotate-passwords --generate
```

Environment-driven rotation:

```bash
DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_PASSWORD='use-a-long-random-value' ./maintain.sh rotate-passwords --from-env
```

Production policy rejects weak passwords by default. Use `--lab`, `HERMES_PASSWORD_POLICY=lab`, or `HERMES_ALLOW_WEAK_PASSWORD=true` only for lab systems.

Plaintext passwords are not printed for env/prompt mode. With `--generate`, the generated value is written under `HERMES_RENDER_DIR` with mode `0600`; this is `current_config/artifacts` for wizard installations and `.rendered` for manual defaults. Move it to your password manager and delete the file.

## Browser token rotation

```bash
./maintain.sh rotate-browser-token
./doctor.sh
```

## Codex re-authentication

```bash
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

See `docs/codex-auth.md`.


## WebUI CDP browser-tool dependency

WebUI chat sessions execute Hermes tools inside the WebUI container. The installer therefore includes a `prepare-browser-cli` initContainer that makes Node and `agent-browser` available under `/opt/data/node/bin` and `/opt/data/node_modules/.bin`. If browser tools fail in WebUI with `agent-browser CLI not found`, rerun `./install.sh` and wait for the WebUI rollout.


## Browserless resource knobs

Repo defaults are lab-friendly:

```bash
BROWSER_CONCURRENT=4
BROWSER_QUEUED=10
BROWSER_TIMEOUT_MS=30000
MODEL_NAME=gpt-5.6-luna
```

With `BROWSER_CONCURRENT=4`, `doctor.sh` can perform active CDP checks while leaving capacity for parallel browser sessions. `BROWSER_QUEUED=10` bounds waiting sessions, and `BROWSER_TIMEOUT_MS=30000` limits one Browserless session to 30 seconds. For screenshot-heavy workflows, increase the concurrency deliberately if Browserless pressure shows sustained queueing.


## WebUI password uses the Dashboard password secret

The WebUI container receives:

```yaml
HERMES_WEBUI_PASSWORD <- secret/hermes-dashboard-auth:password
```

So the WebUI login password is the same value as `DASHBOARD_AUTH_PASSWORD`. This avoids the remote first-password setup gate safely because WebUI auth is enabled at startup. When `maintain.sh rotate-passwords` rotates the dashboard password, it also restarts `hermes-webui` so the env-backed Secret value is reloaded.


## WebUI upload size

The installer sets:

```bash
HERMES_WEBUI_MAX_UPLOAD_MB=220
```

This overrides the upstream WebUI default of 20MiB. Change the value in `hermes.env` and rerun `./install.sh` to update the WebUI deployment.


## Kubernetes resource knobs

The manifest resource requests/limits are configurable through `HERMES_*_CPU_REQUEST`, `HERMES_*_MEMORY_REQUEST`, `HERMES_*_CPU_LIMIT`, and `HERMES_*_MEMORY_LIMIT` variables for Agent, Dashboard, WebUI, and Browser. Defaults stay conservative, but cramped lab clusters can lower requests in their env file.


## Deployment update strategy

Deployment update strategy is `Recreate` for every enabled single-replica component. This avoids surge Pods during `install.sh`/secret refresh restarts, which can otherwise deadlock rollouts on small single-node K3s clusters with tight CPU requests.

### Dashboard workspace file browser

The Dashboard `/files` view must be able to browse `/workspace`. The upstream dashboard locks to `/opt/data` in hosted/container mode unless `HERMES_DASHBOARD_FILES_ROOT` is set, so the installer sets:

```bash
HERMES_DASHBOARD_FILES_ROOT=/workspace
HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace
```

Keep `HERMES_WRITE_SAFE_ROOT` on Agent, Dashboard, and WebUI so file tools use the same safe roots; keep `HERMES_DASHBOARD_FILES_ROOT` on Dashboard for the UI file browser.

## Persistent Python addon packages

The selected profile activates its own `requirements.txt` by default. Set `HERMES_ADDON_REQUIREMENTS` to override it, or set `HERMES_ADDON_REQUIREMENTS=` explicitly to disable addon packages. The requirements file is packaged into the same init Secret mechanism as bootstrap data and installed into a uv-managed Python runtime under `/opt/data`.

```bash
HERMES_ADDON_REQUIREMENTS=./requirements.txt
HERMES_ADDON_PYTHON_VERSION=3.13
ENV_FILE=./hermes.env ./install.sh
```

Operational properties:

- Persistent: the uv runtime and addon venv live on the `/opt/data` PVC and survive Pod recreation.
- Cross-container: the same Python, `ansible`, and other addon CLIs are usable from `hermes-agent`, `hermes-dashboard`, and `hermes-webui` even if the WebUI image has no system Python.
- Re-runnable: changing the requirements file and rerunning `install.sh` updates the venv.
- Isolated: Hermes' own `/opt/hermes/.venv` remains first in the Agent `PATH`; do not install ad-hoc packages there.
- Migrating: if an older non-uv addon venv exists, the init job replaces it with a uv-managed venv.
- Manual installs are supported after the runtime exists:

```bash
kubectl -n <namespace> exec -it deploy/hermes-agent -- /bin/bash
/opt/data/addon-venv/bin/python -m pip install <package>
```

Use absolute paths for the addon interpreter when required:

```bash
/opt/data/addon-venv/bin/python -c "import <package>; print('ok')"
```

If an interactive `kubectl exec` shell resets `PATH`, export the addon path manually for that shell:

```bash
export PATH=/opt/data/addon-venv/bin:/opt/data/uv/bin:$PATH
```

## Persistent HOME and SSH

Agent, Dashboard, and WebUI always use `/opt/data` as persistent Unix home on the `hermes-home` PVC.

SSH setup defaults to `false` for `personal-assistant` and `true` for `universal-system-architect`. Override it explicitly when needed:

```bash
HERMES_SSH_SETUP=true
HERMES_SSH_KEY_TYPE=ed25519
HERMES_SSH_KEY_PATH=/opt/data/.ssh/id_ed25519
```

Operational behavior:

- `HOME=/opt/data`, `XDG_CONFIG_HOME=/opt/data/.config`, and `XDG_CACHE_HOME=/opt/data/.cache` are set on Agent, Dashboard, and WebUI processes.
- If `HERMES_SSH_SETUP=true`, `/opt/data/.ssh` is created with mode `700`, `known_hosts` is created with mode `644`, and the init job generates the key only when `HERMES_SSH_KEY_PATH` does not already exist. Existing keys are preserved.
- Private keys are forced to mode `600`; public keys are forced to mode `644`.

Fetch the generated public key:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- cat /opt/data/.ssh/id_ed25519.pub
```

Manual setup is possible and persistent:

```bash
kubectl -n <namespace> exec -it deploy/hermes-agent -- /bin/bash
mkdir -p /opt/data/.ssh
ssh-keygen -t ed25519 -N '' -f /opt/data/.ssh/id_ed25519
chmod 700 /opt/data/.ssh
chmod 600 /opt/data/.ssh/id_ed25519
chmod 644 /opt/data/.ssh/id_ed25519.pub
```

Keep host key checking enabled. Prefer maintaining `/opt/data/.ssh/known_hosts` or using reviewed per-host `accept-new` entries in `/opt/data/.ssh/config`; do not use global `StrictHostKeyChecking=no` as a default.
