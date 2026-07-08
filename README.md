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
  - initContainer copies Hermes Agent source into an emptyDir
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
- Traefik CRDs if `ENABLE_TRAEFIK_MIDDLEWARE=true`

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
| `BASIC_AUTH_USER` | Outer Ingress BasicAuth username |
| `BASIC_AUTH_PASSWORD` | Outer Ingress BasicAuth password |
| `DASHBOARD_AUTH_USER` | Dashboard internal BasicAuth username |
| `DASHBOARD_AUTH_PASSWORD` | Dashboard internal BasicAuth password |
| `MODEL_PROVIDER` | Initial Hermes provider, default `codex` |
| `MODEL_NAME` | Initial model, default `o4-mini` |
| `HERMES_AGENT_IMAGE` | Agent image |
| `HERMES_WEBUI_IMAGE` | WebUI image |
| `HERMES_BROWSER_IMAGE` | Browserless image |

Secrets may be generated automatically by `install.sh` when variables are omitted.

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
./maintain.sh rotate-passwords
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
- Ingress BasicAuth is optional but strongly recommended if the cluster is public.
- Dashboard has its own internal BasicAuth in addition to optional Ingress BasicAuth.

## License

MIT. See [LICENCE](LICENCE).
