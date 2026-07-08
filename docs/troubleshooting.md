# Troubleshooting

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

Current Hermes Agent images commonly prepare `/opt/data` as `10000:10000`. The installer therefore defaults:

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

If Browserless `/pressure` shows `running` equal to `maxConcurrent` and `queued > 0`, Browserless is saturated. WebUI screenshot/browser workflows may open multiple short-lived CDP sessions in one run, so `BROWSER_CONCURRENT=2` is too low.

Fix in this installer: `install.sh` enforces a minimum:

```bash
BROWSER_CONCURRENT=6
BROWSER_QUEUED=20
```

Then it restarts Agent, Dashboard, WebUI, and Browserless so refreshed Secret/env values take effect.
