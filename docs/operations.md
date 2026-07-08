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

## Password rotation

`maintain.sh rotate-passwords` supports three safe input modes:

1. **Environment variables** for automation/CI.
2. **Interactive hidden prompts** for humans.
3. **Generated values** with `--generate` for break-glass rotation.

Recommended interactive production rotation:

```bash
./maintain.sh rotate-passwords
```

Non-interactive rotation:

```bash
BASIC_AUTH_USER=admin BASIC_AUTH_PASSWORD='use-a-long-random-value' DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_PASSWORD='use-another-long-random-value' ./maintain.sh rotate-passwords
```

Lab rotation with simple passwords:

```bash
./maintain.sh rotate-passwords --lab
```

or:

```bash
HERMES_PASSWORD_POLICY=lab BASIC_AUTH_PASSWORD='labpass' DASHBOARD_AUTH_PASSWORD='labpass' ./maintain.sh rotate-passwords
```

Useful partial rotations:

```bash
./maintain.sh rotate-passwords --skip-ingress      # dashboard only
./maintain.sh rotate-passwords --skip-dashboard    # Traefik BasicAuth only
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

The installer enforces minimum Browserless concurrency values for reliable WebUI browser tools:

```bash
BROWSER_CONCURRENT=6
BROWSER_QUEUED=20
```

Lower values can make Browserless queue CDP handshakes and produce `CDP call timed out ... opening handshake` during full-page screenshot runs.
