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

This includes OAuth state, sessions, skills, memories, workspace files, and WebUI state. Treat backups as sensitive.

## Restore

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.tgz
./doctor.sh
```


## Bootstrap agent configuration

Use `HERMES_BOOTSTRAP_DIR` to seed SOUL, memory, skills, plugins, cron jobs, config, and workspace context into the persistent PVCs. This is useful for repeatable installations where the Agent should start with known behavior.

```bash
cp -a examples/bootstrap ./bootstrap
$EDITOR ./bootstrap/SOUL.md
$EDITOR ./bootstrap/memories/USER.md
cat >> hermes.env <<'EOF'
HERMES_BOOTSTRAP_DIR=./bootstrap
HERMES_BOOTSTRAP_MODE=missing
HERMES_BOOTSTRAP_INCLUDE_AUTH=false
EOF
./install.sh
```

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

Use `HERMES_BOOTSTRAP_MODE=missing` for normal installs/upgrades. Use `overwrite` only when you intentionally want the bootstrap source to replace existing files. Bootstrap data can contain personal data or credentials; keep real `bootstrap/` directories out of git.

## Password rotation

`maintain.sh rotate-passwords` supports three explicit input modes:

1. **Interactive hidden prompts** with `--prompt` — default when stdin is a TTY.
2. **Generated values** with `--generate` — writes new random values to `.rendered/rotated-credentials-*.txt`.
3. **Environment variables** with `--from-env` — intended for automation/CI.

Important: interactive rotation does **not** silently reuse password values from `hermes.env`. If a password is present in the env file and you want to apply exactly that value, say so explicitly with `--from-env`.

Interactive rotation:

```bash
./maintain.sh rotate-passwords --prompt
```

Dashboard + WebUI only, lab password allowed:

```bash
./maintain.sh rotate-passwords --lab --skip-ingress --prompt
# or
./maintain.sh rotate-passwords --lab --only-dashboard --prompt
```

Generate new random values:

```bash
./maintain.sh rotate-passwords --generate
./maintain.sh rotate-passwords --generate --only-dashboard
./maintain.sh rotate-passwords --generate --only-ingress
```

Environment-driven rotation:

```bash
BASIC_AUTH_USER=admin BASIC_AUTH_PASSWORD='use-a-long-random-value' DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_PASSWORD='use-another-long-random-value' ./maintain.sh rotate-passwords --from-env
```

Rotate only one layer:

```bash
./maintain.sh rotate-passwords --skip-ingress --prompt      # dashboard + WebUI only
./maintain.sh rotate-passwords --skip-dashboard --prompt    # Traefik BasicAuth only
```

Production policy rejects weak passwords by default. Use `--lab`, `HERMES_PASSWORD_POLICY=lab`, or `HERMES_ALLOW_WEAK_PASSWORD=true` only for lab systems.

Plaintext passwords are not printed for env/prompt mode. With `--generate`, the generated values are written to a gitignored `.rendered/rotated-credentials-*.txt` file with mode `0600`; move them to your password manager and delete the file.

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
BROWSER_CONCURRENT=1
BROWSER_QUEUED=10
MODEL_NAME=gpt-5.5
ENABLE_TRAEFIK_BASIC_AUTH=false
```

For heavier WebUI screenshot/browser workflows, increase `BROWSER_CONCURRENT` if Browserless queueing causes `CDP call timed out ... opening handshake`.


## WebUI password uses the Dashboard password secret

The WebUI container receives:

```yaml
HERMES_WEBUI_PASSWORD <- secret/hermes-dashboard-auth:password
```

So the WebUI login password is the same value as `DASHBOARD_AUTH_PASSWORD`. This avoids the remote first-password setup gate safely because WebUI auth is enabled at startup. When `maintain.sh rotate-passwords` rotates the dashboard password, it also restarts `hermes-webui` so the env-backed Secret value is reloaded.


## Doctor and Browserless concurrency

With `BROWSER_CONCURRENT=1`, `doctor.sh` skips active CDP navigation and only reports Browserless pressure. A single Hermes browser navigation can open multiple CDP WebSockets, so an active health-test navigation can queue behind itself at concurrency 1. Increase `BROWSER_CONCURRENT` for screenshot-heavy testing or production-like browser workflows.


## WebUI upload size

The installer sets:

```bash
HERMES_WEBUI_MAX_UPLOAD_MB=220
```

This overrides the upstream WebUI default of 20MiB. Change the value in `hermes.env` and rerun `./install.sh` to update the WebUI deployment.


## Kubernetes resource knobs

The manifest resource requests/limits are configurable through `HERMES_*_CPU_REQUEST`, `HERMES_*_MEMORY_REQUEST`, `HERMES_*_CPU_LIMIT`, and `HERMES_*_MEMORY_LIMIT` variables for Agent, Dashboard, WebUI, and Browser. Defaults stay conservative, but cramped lab clusters can lower requests in their env file.


## Deployment update strategy

Deployment update strategy is `Recreate` for the four single-replica components. This avoids surge Pods during `install.sh`/secret refresh restarts, which can otherwise deadlock rollouts on small single-node K3s clusters with tight CPU requests.

### Dashboard workspace file browser

The Dashboard `/files` view must be able to browse `/workspace`. The upstream dashboard locks to `/opt/data` in hosted/container mode unless `HERMES_DASHBOARD_FILES_ROOT` is set, so the installer sets:

```bash
HERMES_DASHBOARD_FILES_ROOT=/workspace
HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace
```

Keep `HERMES_WRITE_SAFE_ROOT` on Agent, Dashboard, and WebUI so file tools use the same safe roots; keep `HERMES_DASHBOARD_FILES_ROOT` on Dashboard for the UI file browser.
