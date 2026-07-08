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
