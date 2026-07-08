# kube.hermes_setup

Production-oriented Kubernetes/K3s installer for a multi-container Hermes Agent stack:

- **Hermes Agent Gateway** (`nousresearch/hermes-agent`) — API/gateway runtime
- **Hermes Dashboard** (`nousresearch/hermes-agent`) — administrative dashboard
- **Hermes WebUI** (`ghcr.io/nesquena/hermes-webui`) — browser chat interface
- **Browserless Chromium** (`ghcr.io/browserless/chromium`) — internal real browser/CDP backend for Hermes browser tools

The repository is intentionally template-driven and contains **no real hostnames, passwords, tokens, OAuth state, kubeconfig, or cluster-specific secrets**.

## Architecture

```text
Internet
  |
  v
Ingress Controller / TLS
  |
  +-- optional Traefik BasicAuth middleware
  |     secret/hermes-basic-auth-users (htpasswd users file)
  |
  |-- WEBUI_HOST      -> hermes-webui:8787
  |-- DASHBOARD_HOST  -> hermes-dashboard:9119

namespace: HERMES_NAMESPACE

hermes-agent
  - /opt/data PVC
  - /workspace PVC
  - API server on 8642
  - BROWSER_CDP_URL -> secret/hermes-browser-cdp

hermes-webui
  - /opt/data PVC
  - /workspace PVC
  - initContainer prepares /opt/data/webui ownership for the configured runtime UID/GID
  - initContainer copies Hermes Agent source into an emptyDir
  - initContainer exposes Node + agent-browser from the Agent image for CDP browser tools
  - HERMES_WEBUI_AGENT_DIR=/home/hermeswebui/.hermes/hermes-agent
  - BROWSER_CDP_URL -> secret/hermes-browser-cdp

hermes-browser
  - internal ClusterIP only
  - Browserless Chromium on 3000
  - token protected
  - restricted by NetworkPolicy
```

## Requirements

On the admin workstation:

- `kubectl`
- `openssl`
- `bash`
- Kubernetes context with permissions to create namespace-scoped resources
- Ingress controller compatible with standard Kubernetes Ingress
- Traefik CRDs if `ENABLE_TRAEFIK_BASIC_AUTH=true`

Optional but recommended:

- `envsubst` from GNU gettext
- `tar`, `sha256sum`

## Quick start

```bash
git clone https://github.com/hermes-speedboat/kube.hermes_setup.git
cd kube.hermes_setup
cp examples/hermes.env.example hermes.env
$EDITOR hermes.env
./install.sh
./doctor.sh
```

Then perform Codex OAuth pairing if you use OpenAI Codex:

```bash
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

See [docs/codex-auth.md](docs/codex-auth.md).

## Configuration

All deployment-specific values go into `hermes.env` or environment variables.

Important variables:

| Variable | Purpose |
|---|---|
| `HERMES_NAMESPACE` | Kubernetes namespace, default `hermes` |
| `WEBUI_HOST` | Public WebUI FQDN |
| `DASHBOARD_HOST` | Public dashboard FQDN |
| `TLS_SECRET_NAME` | Optional TLS secret name if your Ingress uses one |
| `ENABLE_TRAEFIK_BASIC_AUTH` | Enable optional outer Traefik BasicAuth middleware, default `true` |
| `BASIC_AUTH_USER` | Outer Ingress BasicAuth username when Traefik BasicAuth is enabled |
| `BASIC_AUTH_PASSWORD` | Outer Ingress BasicAuth password when Traefik BasicAuth is enabled |
| `DASHBOARD_AUTH_USER` | Dashboard internal BasicAuth username |
| `DASHBOARD_AUTH_PASSWORD` | Dashboard internal BasicAuth password |
| `HERMES_PASSWORD_POLICY` | `production` or `lab` for `maintain.sh rotate-passwords` |
| `MODEL_PROVIDER` | Initial Hermes provider, default `codex` |
| `MODEL_NAME` | Initial model, default `o4-mini` |
| `HERMES_AGENT_IMAGE` | Agent image |
| `HERMES_WEBUI_IMAGE` | WebUI image |
| `HERMES_BROWSER_IMAGE` | Browserless image |
| `HERMES_RUNTIME_UID`, `HERMES_RUNTIME_GID` | Shared PVC owner for Agent/Dashboard/WebUI, default `10000` |

Secrets may be generated automatically by `install.sh` when variables are omitted. The generated/used initial values are written to `.rendered/generated-credentials.txt` with mode `0600`; this path is gitignored, but you should still move the values to a password manager and delete the file after installation.

### Authentication layers

There are two independent authentication layers:

1. **Optional Traefik Ingress BasicAuth** in front of WebUI and Dashboard.
   - Controlled by `ENABLE_TRAEFIK_BASIC_AUTH=true|false`.
   - Implemented as a Traefik `Middleware` plus an `htpasswd`-style Kubernetes Secret.
   - Recommended for public Internet exposure.
   - Often disabled in trusted labs, VPN-only environments, or when another upstream auth proxy already protects the Ingress.
2. **Dashboard internal BasicAuth** inside Hermes Dashboard.
   - Always configured by this installer.
   - Uses `DASHBOARD_AUTH_USER` / `DASHBOARD_AUTH_PASSWORD`.

Password rotation reads values from environment variables or asks interactively with hidden prompts:

```bash
# Interactive; production policy by default
./maintain.sh rotate-passwords [--lab] [--generate] [--skip-ingress] [--skip-dashboard]

# Lab: allow simple passwords after explicit opt-in
./maintain.sh rotate-passwords --lab

# Non-interactive / CI
BASIC_AUTH_PASSWORD='...' DASHBOARD_AUTH_PASSWORD='...' ./maintain.sh rotate-passwords [--lab] [--generate] [--skip-ingress] [--skip-dashboard]
```

Production mode rejects weak passwords by default. Lab mode is explicit because accidental weak public credentials are how horror stories begin.

## Repository layout

```text
.
├── README.md
├── LICENCE
├── install.sh                  # setup/install/upgrade apply
├── maintain.sh                 # backup, restore, upgrade, password rotation
├── doctor.sh                   # health checks and diagnostics
├── examples/
│   └── hermes.env.example
├── manifests/
│   └── hermes.yaml.tpl         # Kubernetes manifest template
└── docs/
    ├── codex-auth.md
    ├── operations.md
    └── security.md
```

## Install

```bash
cp examples/hermes.env.example hermes.env
$EDITOR hermes.env
./install.sh
```

`install.sh` will:

1. load `hermes.env`;
2. validate required values;
3. generate ephemeral secret values if missing;
4. render `manifests/hermes.yaml.tpl` into `.rendered/hermes.yaml`;
5. create/update required Kubernetes Secrets;
6. apply the manifest;
7. wait for rollouts;
8. print next steps.

## Maintain

```bash
./maintain.sh status
./maintain.sh backup ./backups/hermes-$(date -u +%Y%m%dT%H%M%SZ).tgz
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.tgz
./maintain.sh upgrade
./maintain.sh rotate-passwords [--lab] [--generate] [--skip-ingress] [--skip-dashboard]
./maintain.sh rotate-browser-token
./maintain.sh restart
```

See [docs/operations.md](docs/operations.md).

## Doctor

```bash
./doctor.sh
```

Checks:

- Kubernetes context
- namespace/resources
- pod readiness
- service health
- Ingress HTTP status
- WebUI Agent source mount
- Browserless/CDP wiring
- NetworkPolicy reachability
- Codex OAuth state presence

## Codex OAuth

A fresh namespace/PVC rebuild will not contain OpenAI Codex OAuth state. Pair it manually:

```bash
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

OAuth state is stored in:

```text
/opt/data/auth.json
```

Back up `/opt/data` to preserve Codex auth across destructive rebuilds.

## Security model

- Do not commit `hermes.env`.
- Do not commit `.rendered/`.
- Do not put real `BROWSER_CDP_URL` values into `config.yaml`; it contains a token.
- Browserless has no public Ingress.
- Browserless access is token-protected and NetworkPolicy-restricted.
- Traefik Ingress BasicAuth is optional (`ENABLE_TRAEFIK_BASIC_AUTH`) but strongly recommended if the cluster is public.
- Dashboard has its own internal BasicAuth in addition to optional Ingress BasicAuth.

## License

MIT. See [LICENCE](LICENCE).


## Runtime UID/GID and shared PVC ownership

The Agent, Dashboard, and WebUI share the `hermes-home` PVC at `/opt/data`. Current `nousresearch/hermes-agent` images prepare that directory as UID/GID `10000`, so the installer defaults `HERMES_RUNTIME_UID=10000` and `HERMES_RUNTIME_GID=10000` and passes those values to the WebUI as `WANTED_UID` / `WANTED_GID`.

If you pin images with different runtime ownership, set both variables explicitly in `hermes.env` before running `install.sh`.


## WebUI browser tools and CDP

The WebUI container also runs Hermes tools locally for WebUI chat sessions. It therefore needs the `agent-browser` controller even when an external Browserless/CDP endpoint is configured through `BROWSER_CDP_URL`.

The installer prepares this by copying `node` from the Agent image into `/opt/data/node/bin` and linking `/opt/data/node_modules` to the mounted Agent source tree's `node_modules`. This makes `/opt/data/node_modules/.bin/agent-browser` available to the WebUI without installing Chromium locally; Browserless remains the actual browser backend.


## Browserless concurrency

WebUI browser-tool workflows can open several short-lived CDP sessions in one agent run. The installer enforces a minimum `BROWSER_CONCURRENT=6` and `BROWSER_QUEUED=20` even if lower values are provided, because `BROWSER_CONCURRENT=2` can cause Browserless queueing and Hermes-side `CDP call timed out during opening handshake` errors.
