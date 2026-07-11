# kube.hermes_setup

Production-oriented Kubernetes/K3s installer for a multi-container Hermes Agent stack:

- **[Hermes Agent Gateway](https://github.com/nousresearch/hermes-agent)** (`nousresearch/hermes-agent`) — API/gateway runtime
- **[Hermes Dashboard](https://github.com/nousresearch/hermes-agent)** (`nousresearch/hermes-agent`) — administrative dashboard
- **[Hermes WebUI](https://github.com/nesquena/hermes-webui)** (`ghcr.io/nesquena/hermes-webui`) — browser chat interface
- **[Browserless Chromium](https://github.com/browserless/browserless/pkgs/container/chromium)** (`ghcr.io/browserless/chromium`) — internal real browser/CDP backend for Hermes browser tools

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
git clone https://github.com/Bitbull-Ideas/kube.hermes_setup.git
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
| `ENABLE_TRAEFIK_BASIC_AUTH` | Enable optional outer Traefik BasicAuth middleware, default `false` |
| `BASIC_AUTH_USER` | Outer Ingress BasicAuth username when Traefik BasicAuth is enabled |
| `BASIC_AUTH_PASSWORD` | Outer Ingress BasicAuth password when Traefik BasicAuth is enabled |
| `DASHBOARD_AUTH_USER` | Dashboard internal BasicAuth username |
| `DASHBOARD_AUTH_PASSWORD` | Dashboard internal BasicAuth password; also used as WebUI password via `HERMES_WEBUI_PASSWORD` |
| `HERMES_PASSWORD_POLICY` | `production` or `lab` for `maintain.sh rotate-passwords` |
| `MODEL_PROVIDER` | Initial Hermes provider, default `codex` |
| `MODEL_NAME` | Initial model, default `gpt-5.5` |
| `HERMES_AGENT_IMAGE` | Agent image |
| `HERMES_WEBUI_IMAGE` | WebUI image |
| `HERMES_BROWSER_IMAGE` | Browserless image |
| `HERMES_RUNTIME_UID`, `HERMES_RUNTIME_GID` | Shared PVC owner for Agent/Dashboard/WebUI, default `10000` |
| `HERMES_WEBUI_MAX_UPLOAD_MB` | WebUI upload cap in MiB, default `220` |
| `HERMES_DASHBOARD_FILES_ROOT` | Dashboard `/files` root, set by manifest to `/workspace` |
| `HERMES_WRITE_SAFE_ROOT` | Safe write roots, set by manifest to `/opt/data:/workspace` |
| `HERMES_BOOTSTRAP_DIR` | Optional local bootstrap directory for SOUL.md, memories, skills, plugins, cron, config, and workspace files |
| `HERMES_BOOTSTRAP_MODE` | `disabled`, `missing` (default), or `overwrite` |
| `HERMES_ADDON_REQUIREMENTS` | Optional local `requirements.txt` installed into a persistent addon venv |
| `HERMES_ADDON_VENV` | Persistent addon venv path, default `/opt/data/addon-venv` |

Secrets may be generated automatically by `install.sh` when variables are omitted. The generated/used initial values are written to `.rendered/generated-credentials.txt` with mode `0600`; this path is gitignored, but you should still move the values to a password manager and delete the file after installation.

### Authentication layers

There are three independent authentication layers:

1. **Optional Traefik Ingress BasicAuth** in front of WebUI and Dashboard.
   - Controlled by `ENABLE_TRAEFIK_BASIC_AUTH=true|false`.
   - Implemented as a Traefik `Middleware` plus an `htpasswd`-style Kubernetes Secret.
   - Recommended for public Internet exposure.
   - Often disabled in trusted labs, VPN-only environments, or when another upstream auth proxy already protects the Ingress.
2. **Dashboard internal BasicAuth** inside Hermes Dashboard.
   - Always configured by this installer.
   - Uses `DASHBOARD_AUTH_USER` / `DASHBOARD_AUTH_PASSWORD`.
3. **WebUI built-in password auth** inside Hermes WebUI.
   - Always configured by this installer.
   - Uses the same password Secret as Dashboard: `HERMES_WEBUI_PASSWORD` is read from `secret/hermes-dashboard-auth:password`.
   - This avoids the remote first-password setup gate without setting `HERMES_WEBUI_ONBOARDING_OPEN=1`.

Password rotation has explicit input modes. Interactive runs prompt by default and do **not** silently reuse password values from `hermes.env`:

```bash
# Ask for all selected passwords interactively; production policy by default
./maintain.sh rotate-passwords --prompt

# Dashboard + WebUI only, lab password allowed, hidden prompt
./maintain.sh rotate-passwords --lab --skip-ingress --prompt

# Generate random values for selected targets and write them to .rendered/rotated-credentials-*.txt
./maintain.sh rotate-passwords --generate

# Non-interactive / CI: explicitly read from environment variables
BASIC_AUTH_PASSWORD='***' DASHBOARD_AUTH_PASSWORD='***' ./maintain.sh rotate-passwords --from-env
```

Use `--only-ingress`, `--only-dashboard`, `--skip-ingress`, and `--skip-dashboard` to choose exactly which passwords are changed. Production mode rejects weak passwords by default. Lab mode is explicit because accidental weak public credentials are how horror stories begin.


## Bootstrap existing configuration

You can seed a new or existing installation with agent configuration files by setting `HERMES_BOOTSTRAP_DIR` in `hermes.env` and rerunning `./install.sh`. The installer packages the local directory into `.rendered/bootstrap.tar.gz`, uploads it as the `hermes-bootstrap-archive` Kubernetes Secret, and the init job copies it into the persistent PVCs.

Supported source layout:

```text
bootstrap/
├── SOUL.md                       -> /opt/data/SOUL.md
├── config.yaml                   -> /opt/data/config.yaml
├── .env                          -> /opt/data/.env
├── auth.json                     -> /opt/data/auth.json, only when explicitly enabled
├── memories/USER.md              -> /opt/data/memories/USER.md
├── memories/MEMORY.md            -> /opt/data/memories/MEMORY.md
├── skills/<name>/SKILL.md        -> /opt/data/skills/<name>/SKILL.md
├── plugins/                      -> /opt/data/plugins/
├── cron/                         -> /opt/data/cron/
└── workspace/AGENTS.md           -> /workspace/AGENTS.md
```

Example:

```bash
cp -a examples/bootstrap ./bootstrap
# edit ./bootstrap/* for your installation
cat >> hermes.env <<'EOF'
HERMES_BOOTSTRAP_DIR=./bootstrap
HERMES_BOOTSTRAP_MODE=missing
HERMES_BOOTSTRAP_INCLUDE_AUTH=false
EOF
./install.sh
./doctor.sh
```

Modes:

- `missing` copies only files that do not already exist on the PVC. This is safest for upgrades.
- `overwrite` replaces existing bootstrap-managed files/directories. Use deliberately.
- `disabled` ignores `HERMES_BOOTSTRAP_DIR`.

`auth.json` is excluded unless `HERMES_BOOTSTRAP_INCLUDE_AUTH=true`. Treat bootstrap archives as sensitive if they contain memories, `.env`, OAuth state, or private skills. The local `bootstrap/` and `.rendered/` paths are gitignored.

## Persistent Python addon packages

You can install additional Python CLI/tools without rebuilding the Agent image by pointing `HERMES_ADDON_REQUIREMENTS` at a local requirements file. The installer packages that file into the init Secret and the init job installs it into `HERMES_ADDON_VENV`, which must live under the persistent `/opt/data` PVC.

Example:

```bash
cp examples/bootstrap/requirements.txt ./bootstrap/requirements.txt
# edit ./bootstrap/requirements.txt, preferably with pinned versions
cat >> hermes.env <<'EOF'
HERMES_ADDON_REQUIREMENTS=./bootstrap/requirements.txt
HERMES_ADDON_VENV=/opt/data/addon-venv
EOF
ENV_FILE=./hermes.env ./install.sh
```

The Agent container PATH includes the addon venv after Hermes' own venv:

```text
/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/addon-venv/bin:/opt/data/.local/bin:...
```

This makes console scripts installed by the requirements file available to Hermes terminal calls while keeping Hermes' own Python environment first. If you need the addon Python interpreter itself, call it explicitly:

```bash
/opt/data/addon-venv/bin/python -c "import requests; print(requests.__version__)"
```

Manual installs are also possible and persistent because the venv is on the PVC:

```bash
kubectl -n <namespace> exec -it deploy/hermes-agent -- /bin/bash
python3 -m venv /opt/data/addon-venv
/opt/data/addon-venv/bin/pip install --upgrade pip
/opt/data/addon-venv/bin/pip install <package>
```

Some interactive shells reset `PATH`. If `echo $PATH` does not show the addon venv, either use absolute paths or export it for that shell:

```bash
export PATH=/opt/data/addon-venv/bin:$PATH
```

Do not mutate `/opt/hermes/.venv` or install ad-hoc packages into `/usr/local` if persistence matters. For production-standard system tools or OS packages, prefer a custom `HERMES_AGENT_IMAGE`.

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
./maintain.sh rotate-passwords [--lab] [--prompt|--generate|--from-env] [--skip-ingress] [--skip-dashboard]
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

Repo defaults are intentionally lab-friendly: `BROWSER_CONCURRENT=1`, `BROWSER_QUEUED=10`, `MODEL_NAME=gpt-5.5`, and `ENABLE_TRAEFIK_BASIC_AUTH=false`. For heavier WebUI screenshot/browser workflows, raise `BROWSER_CONCURRENT` if Browserless queueing causes `CDP call timed out during opening handshake`.


## WebUI upload size

Upstream Hermes WebUI defaults file uploads to 20MiB via `MAX_UPLOAD_BYTES`. This installer sets `HERMES_WEBUI_MAX_UPLOAD_MB=220` by default so 200MB-class documents can be uploaded with multipart overhead through the WebUI. Increase the value explicitly in `hermes.env` if needed and rerun `./install.sh`.


## Kubernetes resource knobs

The manifest resource requests/limits are configurable through `HERMES_*_CPU_REQUEST`, `HERMES_*_MEMORY_REQUEST`, `HERMES_*_CPU_LIMIT`, and `HERMES_*_MEMORY_LIMIT` variables for Agent, Dashboard, WebUI, and Browser. Defaults stay conservative, but cramped lab clusters can lower requests in their env file.

### Dashboard workspace file browser

The Dashboard `/files` view needs `HERMES_DASHBOARD_FILES_ROOT=/workspace`. This installer also sets `HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace` in Agent, Dashboard, and WebUI so file tools can safely use both PVCs.
