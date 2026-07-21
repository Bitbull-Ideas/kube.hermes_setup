# Security notes

## Do not commit secrets

Never commit:

- `hermes.env`
- rendered manifests under `.rendered/`
- backups
- kubeconfigs
- OAuth files such as `auth.json`
- tokens/passwords/API keys

The repository `.gitignore` excludes the common local files, but operators are still responsible for review before commit.

## Browserless/CDP

Browserless is powerful: it can fetch websites from inside your cluster. This repository therefore:

- exposes Browserless as `ClusterIP` only;
- uses a token;
- stores the CDP URL in a Kubernetes Secret;
- injects `BROWSER_CDP_URL` into Hermes containers;
- restricts access using NetworkPolicy.

The expected redacted endpoint is:

```text
ws://hermes-browser:3000/chromium?token=<redacted>
```

This follows Browserless' documented direct CDP connection path. The endpoint is generated from `BROWSER_TOKEN`, stored in Secret `hermes-browser-cdp`, and injected into the three Hermes runtime containers. Never print the full value in logs or docs. See the [Browserless connection URL patterns](https://docs.browserless.io/baas/connection-url-patterns).

## Authentication

The setup has two application auth layers:

| Layer | Scope | Controlled by | Notes |
|---|---|---|---|
| Hermes Dashboard BasicAuth | Dashboard application login | `DASHBOARD_AUTH_USER` / `DASHBOARD_AUTH_PASSWORD` | Always configured |
| Hermes WebUI password auth | WebUI application login | `HERMES_WEBUI_PASSWORD` from `secret/hermes-dashboard-auth:password` | Always configured |

## TLS

Terminate TLS at your Ingress controller. This template supports Ingress TLS references but does not manage certificates.

## Backups

Backups include OAuth state and possibly user/session data. Store them encrypted and restrict access.

## Password policy

`maintain.sh rotate-passwords` defaults to production policy:

- minimum 14 characters;
- lower-case, upper-case, digit, and symbol required;
- weak values are rejected unless lab mode is explicit.

For lab systems only:

```bash
./maintain.sh rotate-passwords --lab
# or
HERMES_PASSWORD_POLICY=lab ./maintain.sh rotate-passwords
```

The scripts avoid passing plaintext passwords as command-line arguments to `openssl` or `kubectl`.

## Local generated credential files

`install.sh` writes `.rendered/generated-credentials.txt` with mode `0600` so operators can save generated initial values before deleting the file.

`maintain.sh rotate-passwords --generate` writes `.rendered/rotated-credentials-*.txt` with mode `0600` for the same reason. Interactive rotation prompts by default and does not silently reuse password values from `hermes.env`; use `--from-env` explicitly for CI/env-driven changes.

`.rendered/` is gitignored. Treat these files as secrets and remove them after storing values in a password manager.



## WebUI first-password bootstrap

Current Hermes WebUI intentionally blocks unauthenticated remote first-password setup unless the operator sets:

```bash
HERMES_WEBUI_ONBOARDING_OPEN=1
```

This installer does **not** set that escape hatch by default. Instead, it enables WebUI password auth at process start by injecting:

```yaml
HERMES_WEBUI_PASSWORD <- secret/hermes-dashboard-auth:password
```

The WebUI password is therefore the same value as `DASHBOARD_AUTH_PASSWORD`. `HERMES_WEBUI_ONBOARDING_OPEN=1` should only be used as a temporary, operator-controlled bootstrap exception when you intentionally manage WebUI password setup yourself.


## Upload size

`HERMES_WEBUI_MAX_UPLOAD_MB` controls the WebUI upload cap. The default is 220MiB in this installer. Larger caps increase memory/disk pressure because uploads are parsed server-side; raise deliberately and monitor resource usage.


## API server key length

Hermes Agent refuses to start the API server when `API_SERVER_KEY` is a placeholder or shorter than 16 characters. `install.sh` therefore generates a strong replacement if a too-short value is inherited from the environment. Use a high-entropy value such as `openssl rand -hex 32` for explicit production configuration.

## Bootstrap data

`HERMES_BOOTSTRAP_DIR` can contain SOUL.md, memories, skills, plugins, cron jobs, `.env`, and optionally `auth.json`. Treat real bootstrap directories and `.rendered/bootstrap.tar.gz` as sensitive. The repo ignores local `bootstrap/` and `.rendered/`; commit sanitized examples under `examples/bootstrap-shared/` and `examples/bootstrap-profiles/`.

`HERMES_BOOTSTRAP_INCLUDE_AUTH=false` is the default. Enable it only when you deliberately restore OAuth state from a protected source.
