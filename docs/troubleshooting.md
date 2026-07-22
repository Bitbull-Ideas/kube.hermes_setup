# Troubleshooting

## Generated Dashboard/WebUI password cannot be found

If the wizard password prompt was left empty, the question phase does not store a password in `current_config/hermes.env` or `configuration_answers`. `install.sh` generates and applies it later. For a wizard installation, check:

```bash
stat -c '%a %n' current_config/artifacts/generated-credentials.txt
```

Expected mode: `600`. The exact location is `$HERMES_RENDER_DIR/generated-credentials.txt`; manual installations without `HERMES_RENDER_DIR` use `.rendered/generated-credentials.txt`.

Do not post the file contents. Move required values to a password manager. If the file no longer exists, an authorized cluster operator can recover the current Dashboard/WebUI password from `secret/hermes-dashboard-auth`. The following command prints the secret and must be used only in a private terminal:

```bash
kubectl -n <namespace> get secret hermes-dashboard-auth -o jsonpath='{.data.password}' | base64 -d; printf '\n'
```

If both Dashboard and WebUI are disabled, no application password is generated and the `DASHBOARD_AUTH_PASSWORD` entry in the capture file is empty. If an empty password remains configured, each installer rerun generates a new value and overwrites the capture file with the currently applied value.

## WebUI loads but chat fails with `AIAgent not available`

The WebUI needs local access to the Hermes Agent source tree.

This setup uses an initContainer to copy `/opt/hermes` from the agent image into an `emptyDir` mounted read-only at:

```text
/home/hermeswebui/.hermes/hermes-agent
```

Verify:

```bash
kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-webui -- sh -lc 'test -f /home/hermeswebui/.hermes/hermes-agent/run_agent.py && echo ok'
```

## Browser tools fail

Check:

```bash
kubectl -n "$HERMES_NAMESPACE" get deploy hermes-browser
kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-cdp
kubectl -n "$HERMES_NAMESPACE" get networkpolicy hermes-browser-restrict -o yaml
```

The endpoint must include `/chromium`:

```text
ws://hermes-browser:3000/chromium?token=<redacted>
```

Run:

```bash
./doctor.sh
```

## Dashboard redirects to broken login route

Some dashboard versions redirect `/` to `/auth/login?provider=basic&next=%2F`. This setup includes a separate `hermes-dashboard-login` Ingress path with a Traefik `replacePath` middleware to route `/auth/login` to `/auth/password-login`.

## Codex provider not authenticated

Run:

```bash
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

See `docs/codex-auth.md`.


## WebUI cannot create `/opt/data/webui`

Symptom:

```text
mkdir: cannot create directory '/opt/data': Permission denied
!! ERROR: Failed to create state directory at /opt/data/webui
```

Cause: the WebUI container runs as the configured runtime UID/GID, but a freshly provisioned PVC can initially be owned by root. `fsGroup` alone is not reliable enough across all storage classes, and deployments may start before a one-shot config job finishes preparing the shared PVC.

Fix in this installer: the WebUI deployment has a `prepare-webui-state` initContainer that mounts the same PVCs, creates `/opt/data/webui`, and chowns `/opt/data` and `/workspace` to the configured runtime UID/GID before the WebUI process starts. Agent and Dashboard also have `prepare-permissions` initContainers for the same reason.

If you still see the error after upgrading the installer, restart the deployment:

```bash
kubectl -n "$HERMES_NAMESPACE" rollout restart deploy/hermes-webui
kubectl -n "$HERMES_NAMESPACE" rollout status deploy/hermes-webui --timeout=600s
```


## UID/GID mismatch on shared PVCs

Symptom: WebUI init succeeds, but the main container still fails with `/opt/data` permission errors.

Check ownership:

```bash
kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-agent -- sh -lc 'id; ls -ldn /opt/data /workspace'
```

The installer uses `10000:10000` as its default shared PVC ownership contract:

```bash
HERMES_RUNTIME_UID=10000
HERMES_RUNTIME_GID=10000
```

These values are used for initContainer `chown`, Pod `fsGroup`, and WebUI `WANTED_UID` / `WANTED_GID`. If you use images with different ownership, set both variables in `hermes.env` and rerun `./install.sh`.


## `agent-browser CLI not found` in WebUI while CDP is configured

Symptom from a WebUI chat run:

```text
agent-browser CLI not found: agent-browser CLI not found. Install it with: npm install -g agent-browser && agent-browser install --with-deps
```

Cause: `BROWSER_CDP_URL` only points Hermes to Browserless as the browser backend. Hermes still needs the local `agent-browser` Node controller to speak CDP. The Agent image ships Node and `agent-browser`; the WebUI image does not.

Fix in this installer: the `prepare-browser-cli` initContainer copies `node` from the Agent image to `/opt/data/node/bin/node` and exposes the mounted Agent source `node_modules` through `/opt/data/node_modules`. The WebUI `PATH` includes both directories.

Verification:

```bash
kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-webui -- sh -lc '
  /app/venv/bin/python - <<"PY"
from tools.browser_tool import _find_agent_browser, _get_cdp_override, browser_navigate
print(_find_agent_browser(validate=True))
print(_get_cdp_override().split("?", 1)[0])
print(browser_navigate("https://example.com", task_id="webui-cdp-check")[:500])
PY'
```

Expected: path under `/opt/data/node_modules/.bin/agent-browser`, CDP endpoint `ws://hermes-browser:3000/chromium`, and a successful navigation result with `stealth_features: ["cdp_override"]`.


## `CDP call timed out ... opening handshake`

Symptom:

```text
CDP call timed out after 10.0s: timed out during opening handshake
```

If Browserless `/pressure` shows `running` equal to `maxConcurrent` and `queued > 0`, Browserless is saturated. The repo default is intentionally small for lab use:

```bash
BROWSER_CONCURRENT=4
BROWSER_QUEUED=10
BROWSER_TIMEOUT_MS=30000
```

With `BROWSER_CONCURRENT=4`, four Browserless sessions can run in parallel. `BROWSER_TIMEOUT_MS=30000` limits an individual Browserless session to 30 seconds. If Browserless pressure shows sustained queueing, increase concurrency or reduce parallel browser workload before increasing the queue.


## WebUI: `First password setup is only available from local networks`

Current Hermes WebUI intentionally rejects unauthenticated remote first-password setup unless the operator sets:

```bash
HERMES_WEBUI_ONBOARDING_OPEN=1
```

This is a bootstrap escape hatch, not a good steady-state setting for public deployments.

This installer avoids the problem by setting WebUI auth at process start:

```yaml
HERMES_WEBUI_PASSWORD:
  valueFrom:
    secretKeyRef:
      name: hermes-dashboard-auth
      key: password
```

That means the WebUI password is the same as `DASHBOARD_AUTH_PASSWORD`. If the value is rotated, rerun `./maintain.sh rotate-passwords` or restart `deploy/hermes-webui` after updating the Secret so the env value is reloaded.


## `rotate-passwords` did not ask for a password

Current behavior: interactive runs should prompt by default. To be explicit, use:

```bash
./maintain.sh rotate-passwords --lab --prompt
```

If you want to apply values from environment variables or `hermes.env`, use:

```bash
./maintain.sh rotate-passwords --from-env
```

If you want new random values, use:

```bash
./maintain.sh rotate-passwords --generate
```

This separation prevents a fake rotation where `maintain.sh` silently reapplies the old password from `hermes.env`.


## WebUI upload fails around 20MB

Upstream Hermes WebUI defaults `MAX_UPLOAD_BYTES` to 20MiB and exposes the override as:

```bash
HERMES_WEBUI_MAX_UPLOAD_MB=220
```

This installer injects that variable into the WebUI deployment. Verify the effective value:

```bash
kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-webui -- sh -lc '
  /app/venv/bin/python - <<"PY"
from api.config import MAX_UPLOAD_BYTES
print(MAX_UPLOAD_BYTES)
PY'
```

Expected for the default: `230686720` bytes.


## Agent refuses API server key

Symptom in `hermes-agent` logs:

```text
API_SERVER_KEY is a placeholder or too short (<16 chars)
```

Cause: a weak `API_SERVER_KEY` was inherited from the environment or env file. Current `install.sh` generates a strong replacement when the value is shorter than 16 characters. Rerun `./install.sh` and wait for `deploy/hermes-agent` to roll out.

### Dashboard `/files` returns `403: Path outside managed files root`

Root cause: the upstream Hermes image defaults `HERMES_DASHBOARD_FILES_ROOT` unset and then locks the Dashboard file browser to `/opt/data` when `HERMES_HOME=/opt/data`. In this Kubernetes setup the user workspace is mounted separately at `/workspace`, so the Dashboard file browser rejects `/workspace` unless the Dashboard files root is configured.

Expected env:

```bash
# Dashboard container; controls `/files` locked root
HERMES_DASHBOARD_FILES_ROOT=/workspace

# Agent, Dashboard, and WebUI; controls safe write roots for file tools
HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace
```

Verify in the Dashboard pod:

```bash
kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-dashboard -- \
  sh -lc 'echo dashboard_files_root=$HERMES_DASHBOARD_FILES_ROOT; echo write_safe_root=$HERMES_WRITE_SAFE_ROOT; ls -ld /opt/data /workspace'
```
