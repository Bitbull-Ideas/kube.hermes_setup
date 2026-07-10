# Agent maintainer guide for `kube.hermes_setup`

This file is for coding agents and human maintainers working on this repository. It captures project context, repository rules, validation commands, and hard-won pitfalls from real K3s/Hermes deployments.

Public AGENTS.md guidance describes this kind of file as a "README for agents": keep it concrete, repo-local, testable, and focused on what future agents must not rediscover the painful way. This repository intentionally uses `AGENT.md` because the maintainer requested that filename; if your tool only auto-loads `AGENTS.md`, read this file manually before editing.

## Repository purpose

This repository packages a production-oriented but lab-friendly Kubernetes/K3s installer for a multi-container Hermes Agent stack:

- `hermes-agent` — Hermes Gateway/API runtime from `nousresearch/hermes-agent`.
- `hermes-dashboard` — Hermes Dashboard from the same Agent image.
- `hermes-webui` — chat WebUI from `ghcr.io/nesquena/hermes-webui`.
- `hermes-browser` — internal Browserless Chromium/CDP backend from `ghcr.io/browserless/chromium`.

The repo is template-driven. It must remain safe for public GitHub: no real hostnames, passwords, tokens, OAuth state, kubeconfigs, generated manifests with real secrets, or backups.

## Current repo defaults

Keep these defaults in source unless the maintainer explicitly asks otherwise:

```bash
MODEL_PROVIDER=codex
MODEL_NAME=gpt-5.5
ENABLE_TRAEFIK_BASIC_AUTH=false
BROWSER_CONCURRENT=1
BROWSER_QUEUED=10
HERMES_RUNTIME_UID=10000
HERMES_RUNTIME_GID=10000
HERMES_WEBUI_MAX_UPLOAD_MB=220
```

Rationale:

- `gpt-5.5` + `codex` is the preferred model/provider default.
- Traefik BasicAuth is optional and disabled by default for lab/upstream-auth environments.
- Browserless concurrency `1` is intentionally lab-friendly. Do not silently raise it in `install.sh`; warn/document instead.
- Runtime UID/GID `10000:10000` matches current Agent/Dashboard image behavior and prevents WebUI PVC permission failures.

## Important files

```text
README.md                         User-facing overview and quick start
LICENCE                           MIT license
install.sh                        Render/apply installer, secret creation, rollout waits
maintain.sh                       Status, backup/restore, restart, password/token rotation
doctor.sh                         Health/diagnostic checks
examples/hermes.env.example       Public example env; no real values
manifests/hermes.yaml.tpl         Kubernetes template
scripts/render_template.py        Env-driven renderer with optional blocks
docs/operations.md                Day-2 runbook
docs/security.md                  Security model and secret-handling rules
docs/troubleshooting.md           Known failure modes and fixes
docs/codex-auth.md                Manual Codex OAuth pairing
```

Generated/local files that must not be committed:

```text
hermes.env
*.env
.rendered/
backups/
*.tgz
kubeconfig*
auth.json
```

## Security rules — do not violate these

1. Never commit or print real credentials, API keys, OAuth tokens, `auth.json`, kubeconfig contents, generated BasicAuth values, Browserless tokens, or backup archives.
2. Never paste generated credential file contents into chat or docs. You may report metadata such as path, mode, and size.
3. Use placeholders in docs/examples:
   - `hermes.example.com`
   - `hermes-admin.example.com`
   - `example.com`
   - `[REDACTED]`
   - `CHANGE_ME`
4. Do not put a real `BROWSER_CDP_URL` in `config.yaml`; it contains a token. Keep it as a Kubernetes Secret-backed environment variable.
5. Treat backups as sensitive. They include `/opt/data` and may contain OAuth state, sessions, memories, skills, credentials, and workspace files.
6. Before every commit, run a leak scan for private hostnames and common secret patterns.

Recommended leak-scan pattern:

```bash
# Define these locally for your environment. Do not hard-code private hostnames here.
SECRET_REGEX='<common-token-or-private-key-regex>'
PRIVATE_HOST_REGEX='<your-private-domain-regex>'

grep -RInE "$SECRET_REGEX|$PRIVATE_HOST_REGEX" . \
  --exclude-dir=.git \
  --exclude-dir=.rendered \
  --exclude='hermes.env' \
  --exclude='her-test.env' \
  && { echo 'possible leak found' >&2; exit 1; } \
  || true
```

## Standard validation commands

Run these before committing normal repo changes:

```bash
bash -n install.sh maintain.sh doctor.sh
python3 -m py_compile scripts/render_template.py
rm -rf scripts/__pycache__
```

Render validation:

```bash
out=/tmp/hermes-rendered.yaml
set -a
. examples/hermes.env.example
set +a
export WEBUI_HOST=hermes.example.com
export DASHBOARD_HOST=hermes-admin.example.com
export BASIC_AUTH_PASSWORD='Strong-Test-Password-1!'
export DASHBOARD_AUTH_PASSWORD='Strong-Test-Password-2!'
export API_SERVER_KEY='test-api-key'
export BROWSER_TOKEN='test-browser-token'
export BROWSER_CDP_URL='ws://hermes-browser:3000/chromium?token=test-browser-token'
python3 scripts/render_template.py manifests/hermes.yaml.tpl "$out"
python3 - <<'PY' "$out"
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    pass
print('yaml ok')
PY
kubectl create --dry-run=client --validate=false -f "$out" >/dev/null
```

If a live cluster is reachable, also run:

```bash
./doctor.sh
```

Do not require a live namespace for purely repo-local documentation/script syntax changes unless the change affects Kubernetes behavior and a cluster is available.

## Git workflow expectations

- Work on `main` unless the maintainer asks for a branch.
- Keep commits small and descriptive.
- Do not commit generated files.
- Commit and push repo fixes once validated unless the maintainer explicitly says not to.
- Mention exact commit SHA in the final response.

## Installer behavior that matters

`install.sh` must be re-runnable:

- It loads `hermes.env` unless `ENV_FILE` points elsewhere.
- It creates/generates Kubernetes Secrets.
- It renders `manifests/hermes.yaml.tpl` to `.rendered/hermes.yaml`.
- It deletes/recreates the one-shot `hermes-init-config` Job before apply. Kubernetes Jobs are immutable enough to make repeat applies painful otherwise.
- It restarts deployments after refreshing Secret-backed env values because Kubernetes does not reload env vars into running Pods.

Keep this restart behavior. It prevents Browserless token mismatch and stale dashboard/WebUI password env values.

## Authentication model

There are three auth layers:

1. Optional Traefik Ingress BasicAuth.
   - Controlled by `ENABLE_TRAEFIK_BASIC_AUTH=true|false`.
   - Uses `secret/hermes-basic-auth-users` containing an htpasswd-style `users` file.
2. Dashboard internal BasicAuth.
   - Always configured.
   - Uses `secret/hermes-dashboard-auth`.
3. WebUI built-in password auth.
   - Always configured by this installer.
   - `HERMES_WEBUI_PASSWORD` is read from `secret/hermes-dashboard-auth:password`.
   - Therefore WebUI password == `DASHBOARD_AUTH_PASSWORD`.

Do not set `HERMES_WEBUI_ONBOARDING_OPEN=1` as a steady-state default. It is only a temporary bootstrap escape hatch for upstream WebUI behavior when auth is not yet enabled.

## Password rotation rules

`maintain.sh rotate-passwords` intentionally separates input modes:

```bash
./maintain.sh rotate-passwords --prompt
./maintain.sh rotate-passwords --generate
./maintain.sh rotate-passwords --from-env
```

Do not reintroduce behavior where interactive rotation silently reuses password values from `hermes.env`. That caused fake rotations where the old password was reapplied without asking.

Useful examples:

```bash
# Dashboard + WebUI only, lab password allowed, hidden prompt
./maintain.sh rotate-passwords --lab --only-dashboard --prompt

# Optional Traefik BasicAuth only
./maintain.sh rotate-passwords --only-ingress --prompt

# Generate new random values for selected targets
./maintain.sh rotate-passwords --generate --only-dashboard

# CI/env-driven mode, explicit only
DASHBOARD_AUTH_PASSWORD='...' ./maintain.sh rotate-passwords --from-env --only-dashboard
```

Generated values go to `.rendered/rotated-credentials-*.txt` with mode `0600`; never commit or print them.

## Codex OAuth behavior

Codex auth is intentionally manual and stored on the shared home PVC:

```bash
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

OAuth state lands in:

```text
/opt/data/auth.json
```

If the namespace and PVC are deleted, Codex must be paired again or `/opt/data` must be restored from a sensitive backup. Never commit or print `auth.json`.

## Browserless/CDP rules

Correct CDP URL shape:

```text
ws://hermes-browser:3000/chromium?token=[REDACTED]
```

The `/chromium` path is required. Missing it commonly causes `400 Bad Request`.

`BROWSER_CDP_URL` must be injected into:

- `hermes-agent`
- `hermes-dashboard`
- `hermes-webui`

NetworkPolicy `hermes-browser-restrict` must allow `hermes-browser:3000` from:

- `app=hermes-agent`
- `app=hermes-dashboard`
- `app=hermes-webui`

Browserless must remain internal: ClusterIP only, token-protected, no public Ingress.

## WebUI-specific browser tooling pitfall

The WebUI container executes Hermes tools locally for WebUI chat sessions. `BROWSER_CDP_URL` alone is not enough. The WebUI also needs the local Node-based `agent-browser` controller.

The installer solves this with `prepare-browser-cli`:

- copy `node` from the Agent image to `/opt/data/node/bin/node`
- expose Agent-source `node_modules` through `/opt/data/node_modules`
- prepend `/opt/data/node/bin:/opt/data/node_modules/.bin` to WebUI `PATH`

Without this, WebUI prompts can fail with:

```text
agent-browser CLI not found
```

while Agent-only CDP smoke tests pass.

## Browserless concurrency pitfall

With repo default:

```bash
BROWSER_CONCURRENT=1
```

an active `browser_navigate()` health test can deadlock/queue behind itself because Hermes/agent-browser may open multiple CDP WebSockets for one navigation. `doctor.sh` therefore checks Browserless `/pressure` and skips active navigation when `maxConcurrent < 2`.

Expected doctor output in lab mode may include:

```text
WARN browserless maxConcurrent=1; skipping active navigation test because Hermes browser_navigate can open multiple CDP sessions
```

That is not a failure. For real screenshot-heavy testing, increase concurrency intentionally:

```bash
BROWSER_CONCURRENT=2 ./install.sh
./doctor.sh
```

If `hermes.env` still contains `BROWSER_CONCURRENT=1`, it can override shell assumptions depending on how the script is invoked. Check rendered Deployment env, not your memory. Memory lies. YAML lies more politely.


## WebUI upload limit pitfall

Upstream Hermes WebUI defaults uploads to 20MiB (`MAX_UPLOAD_BYTES`). This installer must set `HERMES_WEBUI_MAX_UPLOAD_MB=220` in the WebUI container so users can upload larger files. If uploads fail around 20MB, verify the WebUI pod env and `api.config.MAX_UPLOAD_BYTES`.

## Troubleshooting cheat sheet

### WebUI cannot write `/opt/data/webui`

Symptom:

```text
mkdir: cannot create directory '/opt/data': Permission denied
```

Likely cause: UID/GID mismatch on shared PVC. Current default is `10000:10000`; WebUI uses `WANTED_UID` / `WANTED_GID`, Pod `fsGroup`, and initContainer chown with the same values.

### `AIAgent not available`

WebUI lacks the local Agent source tree. Check:

```bash
kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-webui -- sh -lc 'test -f /home/hermeswebui/.hermes/hermes-agent/run_agent.py && echo ok'
```

### CDP `401 Unauthorized`

Usually Browserless token mismatch. If Secrets changed, restart all affected deployments:

```bash
kubectl -n "$HERMES_NAMESPACE" rollout restart deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui deploy/hermes-browser
```

### CDP `400 Bad Request`

Usually missing `/chromium` in the WebSocket URL.

### CDP `Connection refused`

Usually Service/NetworkPolicy/Pod reachability. Check:

```bash
kubectl -n "$HERMES_NAMESPACE" get svc,endpoints hermes-browser -o wide
kubectl -n "$HERMES_NAMESPACE" describe networkpolicy hermes-browser-restrict
```

### CDP opening handshake timeout

Check Browserless pressure:

```bash
BPOD=$(kubectl -n "$HERMES_NAMESPACE" get pod -l app=hermes-browser --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
CDP=$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-cdp -o jsonpath='{.data.BROWSER_CDP_URL}' | base64 -d)
TOKEN="${CDP##*token=}"
kubectl -n "$HERMES_NAMESPACE" exec "$BPOD" -c chromium -- sh -lc 'TOKEN="$0"; wget -qO- "http://127.0.0.1:3000/pressure?token=$TOKEN"' "$TOKEN"
```

Redact tokens before sharing output.

## When editing docs/examples

- Keep examples generic.
- Use `hermes.example.com` and `hermes-admin.example.com` for public hostnames.
- Do not mention live cluster FQDNs.
- Do not include real user/password examples. Use `***`, `[REDACTED]`, or obviously fake strong placeholders.
- If documenting a real pitfall, include the exact symptom and the fix.

## When editing Kubernetes manifests

- Preserve Secret-backed env values; do not inline secrets.
- Preserve `prepare-permissions`, `prepare-webui-state`, `copy-agent-source`, and `prepare-browser-cli` initContainer behavior unless you have tested a better replacement.
- Preserve Browserless as internal ClusterIP only.
- Preserve Traefik BasicAuth as optional; do not make it mandatory again.
- Preserve Dashboard/WebUI shared password behavior unless upstream WebUI adds a better first-class bootstrap API.

## When editing shell scripts

- Keep `set -euo pipefail`.
- Do not pass plaintext passwords in command-line arguments where they appear in process lists.
- Prefer temporary files with restrictive permissions for `kubectl create secret --from-file`.
- Use `openssl passwd -apr1 -stdin` for htpasswd hashes.
- Make scripts idempotent and safe to rerun.
- Support non-interactive automation explicitly; do not guess user intent from stale environment values.

## Useful live debug commands

Use only when a cluster is available and the maintainer asked for live debugging:

```bash
export HERMES_NAMESPACE=her
kubectl -n "$HERMES_NAMESPACE" get deploy,pods,svc,ingress,networkpolicy -o wide
./doctor.sh
```

Visible Agent CDP test:

```bash
APOD=$(kubectl -n "$HERMES_NAMESPACE" get pod -l app=hermes-agent --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$HERMES_NAMESPACE" exec "$APOD" -- sh -lc '
/opt/hermes/.venv/bin/python - <<"PY"
from tools.browser_tool import _get_cdp_override, browser_navigate, browser_snapshot
url = _get_cdp_override()
print("CDP:", url.split("?", 1)[0] if url else None)
print(browser_navigate("https://example.com", task_id="manual-cdp-debug"))
print(browser_snapshot(task_id="manual-cdp-debug")[:1500])
PY
'
```

Browserless logs:

```bash
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-browser -c chromium --tail=200
```

## Final response expectations

When you change this repo, report:

- files changed
- tests actually run
- whether a live cluster was touched
- commit SHA if pushed
- any blockers or assumptions

Be concise, factual, and do not claim tests passed unless they actually ran.


## API server key pitfall

Hermes Agent refuses to start the API server if `API_SERVER_KEY` is a placeholder or shorter than 16 characters. The installer should never propagate such a value from a local shell/env file into Kubernetes; generate a strong replacement instead.


## Kubernetes resource knobs

The manifest resource requests/limits are configurable through `HERMES_*_CPU_REQUEST`, `HERMES_*_MEMORY_REQUEST`, `HERMES_*_CPU_LIMIT`, and `HERMES_*_MEMORY_LIMIT` variables for Agent, Dashboard, WebUI, and Browser. Defaults stay conservative, but cramped lab clusters can lower requests in their env file.


## Deployment update strategy

Deployment update strategy is `Recreate` for the four single-replica components. This avoids surge Pods during `install.sh`/secret refresh restarts, which can otherwise deadlock rollouts on small single-node K3s clusters with tight CPU requests.

### Dashboard `/files` workspace root

The Dashboard file browser is controlled by `HERMES_DASHBOARD_FILES_ROOT`, while file tools use `HERMES_WRITE_SAFE_ROOT`. Upstream hosted/container mode locks Dashboard `/files` to `/opt/data`; this repo mounts the actual workspace at `/workspace`. Set `HERMES_DASHBOARD_FILES_ROOT=/workspace` on Dashboard and `HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace` on Agent, Dashboard, and WebUI. If `/files` shows `403: Path outside managed files root`, check these env vars first.

### Bootstrap feature

`HERMES_BOOTSTRAP_DIR` packages a local directory into `.rendered/bootstrap.tar.gz` and applies it via Kubernetes Secret `hermes-bootstrap-archive`. The init job maps `SOUL.md`, `memories/`, `skills/`, `plugins/`, `cron/`, `config.yaml`, `.env`, and `workspace/` into `/opt/data` and `/workspace`. Default mode is `missing`; `overwrite` is destructive. `auth.json` is excluded unless `HERMES_BOOTSTRAP_INCLUDE_AUTH=true`. Never commit real `bootstrap/` content; only sanitized examples under `examples/bootstrap/`.
