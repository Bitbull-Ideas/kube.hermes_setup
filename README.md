# kube.hermes_setup

Current release: **v2.0.1** (see [`VERSION`](VERSION) and [`CHANGELOG.md`](CHANGELOG.md)).

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
  |-- WEBUI_HOST      -> hermes-webui:8787
  |-- DASHBOARD_HOST  -> hermes-dashboard:9119

namespace: HERMES_NAMESPACE

hermes-agent
  - /opt/data PVC
  - /workspace PVC
  - API server on 8642
  - BROWSER_CDP_URL -> secret/hermes-browser-cdp

hermes-dashboard (optional)
  - /opt/data PVC
  - /workspace PVC
  - Dashboard on 9119
  - HERMES_DASHBOARD_FILES_ROOT=/workspace

hermes-webui (optional)
  - /opt/data PVC
  - /workspace PVC
  - initContainer prepares /opt/data/webui ownership for the configured runtime UID/GID
  - initContainer copies Hermes Agent source into an emptyDir
  - initContainer exposes Node + agent-browser from the Agent image for CDP browser tools
  - HERMES_WEBUI_AGENT_DIR=/home/hermeswebui/.hermes/hermes-agent
  - BROWSER_CDP_URL -> secret/hermes-browser-cdp

hermes-browser (optional)
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
- `python3`
- `tar`
- Kubernetes context with permissions to create namespace-scoped resources
- Ingress controller compatible with standard Kubernetes Ingress

For repository validation, maintainers also need Python `PyYAML` and access to `kubectl create --dry-run=client`.

## Quick start

```bash
git clone https://github.com/Bitbull-Ideas/kube.hermes_setup.git
cd kube.hermes_setup
./setup.sh
```

`setup.sh` runs the interactive configurator and optionally hands off to `install.sh`. It writes deployment settings to `current_config/hermes.env` and creates the native Agent configuration at `current_config/bootstrap/config.yaml`. The existing bootstrap mechanism installs that file as persistent `/opt/data/config.yaml`; normal Pod restarts do not remove it because `/opt/data` is backed by the `hermes-home` PVC. Generated artifacts stay below the Git-ignored `current_config/` directory. Answers are saved separately in the Git-ignored root file `configuration_answers` with mode `0600`.

When the wizard generates the Dashboard/WebUI password, it is created by `install.sh`, not by the question phase. After installation, find the current generated and applied values here:

```text
current_config/artifacts/generated-credentials.txt
```

The wizard prints this exact path before and after installation. The file is mode `0600`; move its values into a password manager and delete it when no longer needed. A blank password remains blank in `current_config/hermes.env` and `configuration_answers`, so every later installer run generates and applies a new password and overwrites the capture file with the new current value.

After pulling repository updates, rebuild clean generated configuration from the saved answers:

```bash
./setup.sh --from-answers
```

For manual configuration, copy `examples/hermes.env.example`, edit it, and run `ENV_FILE=./hermes.env ./install.sh`.

Then perform Codex OAuth pairing if you use OpenAI Codex:

```bash
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

See [docs/codex-auth.md](docs/codex-auth.md).

## Configuration

All deployment-specific values go into `hermes.env` or environment variables.

Agent-native settings such as provider, model, terminal working directory, display behavior, and gateway binding are stored in bootstrap `config.yaml`. Use `HERMES_BOOTSTRAP_MODE=missing` to seed the file once without replacing later Agent-side edits; use `overwrite` only when the generated file should be authoritative on the next installer run.

Important variables:

| Variable | Purpose |
|---|---|
| `HERMES_NAMESPACE` | Kubernetes namespace, default `hermes` |
| `HERMES_AGENT_ENABLED` | Mandatory Agent toggle; must remain `true` |
| `HERMES_DASHBOARD_ENABLED` | Include Dashboard deployment, service, middleware, and ingress |
| `HERMES_WEBUI_ENABLED` | Include WebUI deployment, service, and ingress |
| `HERMES_BROWSER_ENABLED` | Include Browserless deployment, service, and NetworkPolicy |
| `WEBUI_HOST` | Public WebUI FQDN |
| `DASHBOARD_HOST` | Public dashboard FQDN |
| `TLS_SECRET_NAME` | Optional TLS secret name if your Ingress uses one |
| `DASHBOARD_AUTH_USER` | Dashboard internal BasicAuth username |
| `DASHBOARD_AUTH_PASSWORD` | Dashboard internal BasicAuth password; also used as WebUI password via `HERMES_WEBUI_PASSWORD` |
| `HERMES_PASSWORD_POLICY` | `production` or `lab` for `maintain.sh rotate-passwords` |
| `MODEL_PROVIDER` | Initial Hermes provider, default `codex` |
| `MODEL_NAME` | Initial model, default `gpt-5.6-luna` |
| `HERMES_AGENT_IMAGE` | Agent image |
| `HERMES_WEBUI_IMAGE` | WebUI image |
| `HERMES_BROWSER_IMAGE` | Browserless image |
| `HERMES_RUNTIME_UID`, `HERMES_RUNTIME_GID` | Shared PVC owner for Agent/Dashboard/WebUI, default `10000` |
| `HERMES_WEBUI_MAX_UPLOAD_MB` | WebUI upload cap in MiB, default `220` |
| `HERMES_DASHBOARD_FILES_ROOT` | Dashboard `/files` root, set by manifest to `/workspace` |
| `HERMES_WRITE_SAFE_ROOT` | Safe write roots, set by manifest to `/opt/data:/workspace` |
| `HERMES_BOOTSTRAP_DIR` | Optional local bootstrap directory for SOUL.md, memories, skills, plugins, cron, config, and workspace files |
| `HERMES_BOOTSTRAP_MODE` | `disabled`, `missing` (default), or `overwrite` |
| `HERMES_BOOTSTRAP_PROFILE` | Prebuilt profile; defaults to `personal-assistant`; set empty to disable profile composition |
| `HERMES_ADDON_REQUIREMENTS` | Optional local `requirements.txt`; defaults to the selected profile's file; explicit empty disables it |
| `HERMES_ADDON_PYTHON_VERSION` | Optional uv-managed addon Python version, default `3.13` |
| `HERMES_SSH_SETUP` | Prepare `/opt/data/.ssh`; profile default is `false` for personal assistant and `true` for system architect |
| `HERMES_ANSIBLE_SETUP` | Include/create the profile Ansible workspace and expose `ANSIBLE_CONFIG`; profile default follows the selected profile |
| `HERMES_ANSIBLE_CONFIG` | Ansible config path exposed to containers; the default path is generated automatically, while a custom path must be supplied by the selected/custom bootstrap |
| `HERMES_ANSIBLE_VERSION` | Exact `ansible` package version injected into generated requirements when setup is enabled; default `14.1.0` |
| `HERMES_SSH_KEY_PATH` | SSH private key path under `/opt/data/.ssh`, default `/opt/data/.ssh/id_ed25519` |

Secrets may be generated automatically by `install.sh` when variables are omitted. The generated and applied initial values are written with mode `0600` to `$HERMES_RENDER_DIR/generated-credentials.txt`. The wizard sets that directory to `current_config/artifacts`; a manual installation that does not set `HERMES_RENDER_DIR` uses `.rendered`. Both paths are Git-ignored. Move the values to a password manager and delete the file after installation.

If the capture file was already deleted, the shared Dashboard/WebUI password can be recovered from the Kubernetes Secret by an authorized cluster operator. This command prints the password, so run it only in a private terminal and do not paste its output into logs or chat:

```bash
kubectl -n <namespace> get secret hermes-dashboard-auth -o jsonpath='{.data.password}' | base64 -d; printf '\n'
```

### Authentication layers

Application authentication is intentionally simple:

- Dashboard BasicAuth is configured from `DASHBOARD_AUTH_USER` / `DASHBOARD_AUTH_PASSWORD` when Dashboard is selected.
- WebUI password auth uses the same Kubernetes Secret (`secret/hermes-dashboard-auth:password`) when WebUI is selected.

Edge authentication, if required, belongs in your Ingress/auth layer outside this installer.

Password rotation has explicit input modes. Interactive runs prompt by default and do **not** silently reuse password values from `hermes.env`:

```bash
# Ask for the Dashboard/WebUI password interactively; production policy by default
./maintain.sh rotate-passwords --prompt

# Dashboard + WebUI, lab password allowed, hidden prompt
./maintain.sh rotate-passwords --lab --prompt

# Generate a random value under $HERMES_RENDER_DIR
./maintain.sh rotate-passwords --generate

# Non-interactive / CI: explicitly read from environment variables
DASHBOARD_AUTH_PASSWORD='***' ./maintain.sh rotate-passwords --from-env
```

Production mode rejects weak passwords by default. Lab mode is explicit because accidental weak public credentials are how horror stories begin.


## Bootstrap existing configuration

You can seed a new or existing installation with agent configuration files by setting `HERMES_BOOTSTRAP_DIR` in `hermes.env` and rerunning `./install.sh`. The installer packages the local directory into `$HERMES_RENDER_DIR/bootstrap.tar.gz`, uploads it as the `hermes-bootstrap-archive` Kubernetes Secret, and the init job copies it into the persistent PVCs. The wizard sets `HERMES_RENDER_DIR=current_config/artifacts`; a manual installation defaults to `.rendered`.

The preferred path is `HERMES_BOOTSTRAP_PROFILE`. Each profile has a `skills.txt` allowlist and `defaults.conf` defaults. Skills remain canonical under `examples/bootstrap-shared/skills/`; the installer copies only the selected skill directories into the generated archive. Markdown links cannot install a skill, and repository symlinks are avoided because Kubernetes Secret/tar portability is better with generated copies.

| Profile | Selected shared skills | Addon requirements | SSH | Ansible runtime |
|---|---|---|---|---|
| `personal-assistant` | `markdown-pdf`, `hermes-workspace-manager` | profile `requirements.txt` | `false` | `false` |
| `universal-system-architect` | all five shared skills | profile `requirements.txt` with Ansible/cloud packages | `true` | `true` |

Operator values win: explicitly set `HERMES_ADDON_REQUIREMENTS`, `HERMES_SSH_SETUP`, `HERMES_ANSIBLE_SETUP`, `HERMES_ANSIBLE_VERSION`, or `HERMES_ANSIBLE_CONFIG` in `hermes.env` to override the profile default. When Ansible setup is enabled, the installer adds the selected `ansible==<version>` to its generated copy of the addon requirements, even when the selected profile is `personal-assistant`; source requirements are never modified. An explicit empty `HERMES_ADDON_REQUIREMENTS=` disables profile addon packages but still permits the explicitly enabled Ansible package. On a fresh deployment, `HERMES_ANSIBLE_SETUP=false` excludes a profile-provided `workspace/ansible` tree and removes its profile-default Ansible package; it does not delete existing PVC files or rewrite operator-owned custom requirements.

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
│   ├── github-setup-access/      # Low-privilege public GitHub PR access
│   ├── hermes-workspace-ansible/ # Ansible workspace and cleanup conventions
│   ├── hermes-workspace-git/     # Git repository placement and archival rules
│   ├── hermes-workspace-manager/ # Generic topic containment and lifecycle routing
│   └── markdown-pdf/             # Reproducible Markdown-to-PDF workflow
├── plugins/                      -> /opt/data/plugins/
├── cron/                         -> /opt/data/cron/
└── workspace/AGENTS.md           -> /workspace/AGENTS.md
```

Example:

```bash
# Option A: use a prebuilt profile (personal-assistant is the default)
echo 'HERMES_BOOTSTRAP_PROFILE=universal-system-architect' >> hermes.env
./install.sh
./doctor.sh
```

```bash
# Option B: fully custom bootstrap directory (profile defaults still apply)
cp -a examples/bootstrap-shared ./bootstrap
cp -a examples/bootstrap-profiles/personal-assistant/. ./bootstrap/
$EDITOR ./bootstrap/*
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

`auth.json` is excluded unless `HERMES_BOOTSTRAP_INCLUDE_AUTH=true`. Treat bootstrap archives as sensitive if they contain memories, `.env`, OAuth state, or private skills. Local `bootstrap/`, `current_config/`, `configuration_answers`, and `.rendered/` paths are Git-ignored.

The workspace skills are designed to be loaded together. `hermes-workspace-manager` supplies generic topic resolution and lifecycle rules; `hermes-workspace-git` routes Git repositories to `git/` and `git_archive/`, while `hermes-workspace-ansible` routes Ansible-native work to `ansible/` and `ansible_archive/`. A Git repository is the topic folder. For Ansible, the topic scope may be the shared `ansible/` root or an established project/subtree, and archival moves only approved completed paths. Neither workflow creates an additional generic topic copy.

## Persistent HOME and SSH keypair

The Agent, Dashboard, and WebUI containers use the persistent Hermes home PVC as their Unix home directory. The installer sets:

```text
HOME=/opt/data
XDG_CONFIG_HOME=/opt/data/.config
XDG_CACHE_HOME=/opt/data/.cache
```

This keeps CLI state, cache/config files, and addon tooling on the `hermes-home` PVC instead of the ephemeral container filesystem. When `HERMES_SSH_SETUP=true`, the init job also prepares:

```text
/opt/data/.ssh/
/opt/data/.ssh/known_hosts
```

with safe permissions and creates the SSH keypair only if `HERMES_SSH_KEY_PATH` is missing. Existing keys are preserved; private keys are never copied from examples or the public repo.

```bash
HERMES_SSH_SETUP=true
HERMES_SSH_KEY_TYPE=ed25519
HERMES_SSH_KEY_PATH=/opt/data/.ssh/id_ed25519
```

After installation, fetch the public key and install it on target hosts:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- cat /opt/data/.ssh/id_ed25519.pub
```

Manual key management is also supported:

```bash
kubectl -n <namespace> exec -it deploy/hermes-agent -- /bin/bash
mkdir -p /opt/data/.ssh
ssh-keygen -t ed25519 -N '' -f /opt/data/.ssh/id_ed25519
chmod 700 /opt/data/.ssh
chmod 600 /opt/data/.ssh/id_ed25519
chmod 644 /opt/data/.ssh/id_ed25519.pub
```

Do not commit private keys into `bootstrap/` or the public repo. If you bootstrap SSH material manually, treat the generated `$HERMES_RENDER_DIR/bootstrap.tar.gz` and Kubernetes Secret as sensitive.

## Persistent Python addon packages

You can install additional Python CLI/tools without rebuilding the Agent image by pointing `HERMES_ADDON_REQUIREMENTS` at a local requirements file. The installer packages that file into the init Secret and the init job installs it into a uv-managed Python runtime and venv on the persistent `/opt/data` PVC. This makes the addon Python usable from the Agent, Dashboard, and WebUI containers, even when the WebUI image has no system Python.

Hard-coded addon runtime paths:

```text
HERMES_ADDON_PYTHON_MODE=uv
HERMES_UV_DIR=/opt/data/uv
HERMES_ADDON_VENV=/opt/data/addon-venv
```

Only the Python version is configurable:

```bash
HERMES_ADDON_PYTHON_VERSION=3.13
```

Example:

```bash
cp examples/bootstrap-profiles/personal-assistant/requirements.txt ./requirements.txt
# edit ./requirements.txt, preferably with pinned versions
cat >> hermes.env <<'EOF'
HERMES_ADDON_REQUIREMENTS=./requirements.txt
HERMES_ADDON_PYTHON_VERSION=3.13
EOF
ENV_FILE=./hermes.env ./install.sh
```

The Agent and Dashboard container `PATH` values include the addon venv after Hermes' own venv, and the WebUI container `PATH` includes it before its normal paths:

```text
# Agent/Dashboard
/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/addon-venv/bin:/opt/data/uv/bin:...

# WebUI
/opt/data/addon-venv/bin:/opt/data/uv/bin:/opt/data/node/bin:...
```

This makes console scripts installed by the requirements file available to Hermes terminal calls while keeping Hermes' own Python environment first in Agent/Dashboard. If you need the addon Python interpreter itself, call it explicitly:

```bash
/opt/data/addon-venv/bin/python -c "import requests; print(requests.__version__)"
```

Manual installs are also possible and persistent because the venv is on the PVC:

```bash
kubectl -n <namespace> exec -it deploy/hermes-agent -- /bin/bash
/opt/data/addon-venv/bin/python -m pip install <package>
```

Some interactive shells reset `PATH`. If `echo $PATH` does not show the addon venv, either use absolute paths or export it for that shell:

```bash
export PATH=/opt/data/addon-venv/bin:$PATH
```

Do not mutate `/opt/hermes/.venv` or install ad-hoc packages into `/usr/local` if persistence matters. If a previous install created `/opt/data/addon-venv` with system Python, rerunning the installer migrates it to a uv-managed venv so the same Python works from WebUI too. For production-standard system tools or OS packages, prefer a custom `HERMES_AGENT_IMAGE`.

For a persistent Ansible control-node pattern, including mount locations and visible roles/collections paths under `/workspace/ansible`, select `universal-system-architect`; its requirements file is activated automatically unless overridden. See [`docs/ansible.md`](docs/ansible.md).

## Repository layout

```text
.
├── README.md
├── AGENTS.md
├── VERSION
├── LICENCE
├── setup.sh                    # stable wizard entry point
├── configure.sh                # interactive/replay configuration generator
├── install.sh                  # setup/install/upgrade apply
├── maintain.sh                 # backup, restore, upgrade, password rotation
├── doctor.sh                   # health checks and diagnostics
├── scripts/                    # template and requirements helpers
├── tests/                      # profile, wizard, and render matrices
├── examples/
│   ├── hermes.env.example
│   ├── bootstrap-shared/
│   └── bootstrap-profiles/
├── manifests/
│   └── hermes.yaml.tpl         # Kubernetes manifest template
└── docs/
    ├── ansible.md
    ├── codex-auth.md
    ├── operations.md
    ├── security.md
    └── troubleshooting.md
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
3. generate missing secret values and capture the applied values locally;
4. render `manifests/hermes.yaml.tpl` into `$HERMES_RENDER_DIR/hermes.yaml`;
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
./maintain.sh rotate-passwords [--lab] [--prompt|--generate|--from-env]
./maintain.sh rotate-browser-token
./maintain.sh restart
```

See [docs/operations.md](docs/operations.md).

## Doctor

```bash
./doctor.sh
```

Checks Kubernetes reachability, rollouts, internal service health, HOME/SSH/Ansible parity, WebUI agent wiring, Browserless/CDP wiring, upload limits, optional external Ingress status, and Codex OAuth state presence.

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
- Do not commit `current_config/`, `configuration_answers`, or `.rendered/`.
- Do not put real `BROWSER_CDP_URL` values into `config.yaml`; it contains a token.
- Browserless has no public Ingress.
- Browserless access is token-protected and NetworkPolicy-restricted.
- Dashboard has its own internal BasicAuth.

## Runtime UID/GID and shared PVC ownership

The Agent, Dashboard, and WebUI share the `hermes-home` PVC at `/opt/data`. The installer defaults `HERMES_RUNTIME_UID=10000` and `HERMES_RUNTIME_GID=10000`, uses init containers to prepare both PVC mount points with that ownership, and passes the same values to WebUI as `WANTED_UID` / `WANTED_GID`.

If you pin images with different runtime ownership, set both variables explicitly in `hermes.env` before running `install.sh`.


## WebUI browser tools and CDP

The WebUI container also runs Hermes tools locally for WebUI chat sessions. It therefore needs the `agent-browser` controller even when an external Browserless/CDP endpoint is configured through `BROWSER_CDP_URL`.

The installer uses Browserless' documented self-hosted CDP URL shape:

```text
ws://hermes-browser:3000/chromium?token=<redacted>
```

The URL is generated from `BROWSER_TOKEN`, stored in Secret `hermes-browser-cdp`, injected into Agent, Dashboard, and WebUI as `BROWSER_CDP_URL`, and persisted in `/opt/data/.env` by the init job. Browserless remains ClusterIP-only; the URL must not be placed in a public config or committed file. See the [Browserless connection URL documentation](https://docs.browserless.io/baas/connection-url-patterns).

The installer prepares this by copying `node` from the Agent image into `/opt/data/node/bin` and linking `/opt/data/node_modules` to the mounted Agent source tree's `node_modules`. This makes `/opt/data/node_modules/.bin/agent-browser` available to the WebUI without installing Chromium locally; Browserless remains the actual browser backend.


## Browserless concurrency

Repo defaults are tuned for practical browser use: `BROWSER_CONCURRENT=4`, `BROWSER_QUEUED=10`, `BROWSER_TIMEOUT_MS=30000`, and `MODEL_NAME=gpt-5.6-luna`. Keep concurrency at least 4 for parallel WebUI screenshot/browser workflows; lower values can queue and cause `CDP call timed out during opening handshake`.


## WebUI upload size

Upstream Hermes WebUI defaults file uploads to 20MiB via `MAX_UPLOAD_BYTES`. This installer sets `HERMES_WEBUI_MAX_UPLOAD_MB=220` by default so 200MB-class documents can be uploaded with multipart overhead through the WebUI. Increase the value explicitly in `hermes.env` if needed and rerun `./install.sh`.


## Kubernetes resource knobs

The manifest resource requests/limits are configurable through `HERMES_*_CPU_REQUEST`, `HERMES_*_MEMORY_REQUEST`, `HERMES_*_CPU_LIMIT`, and `HERMES_*_MEMORY_LIMIT` variables for Agent, Dashboard, WebUI, and Browser. Defaults stay conservative, but cramped lab clusters can lower requests in their env file.

### Dashboard workspace file browser

The Dashboard `/files` view needs `HERMES_DASHBOARD_FILES_ROOT=/workspace`. This installer also sets `HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace` in Agent, Dashboard, and WebUI so file tools can safely use both PVCs.

## Acknowledgements and contributors

### People

- **[Chris Rüttimann (`joe-speedboat`)](https://github.com/joe-speedboat)** — project maintainer and the human commit contributor represented in this repository's Git history. Historical commits also contain spelling and email variants of the same contributor identity.
- **[Nicolas Eberle (`archham`)](https://github.com/archham)** — honored for ideas, structured operational use cases, inspiration, and reusable skills. In particular, [Hermes Team Policy Template](https://github.com/Tuxmint-Open-Source/hermes-team-policy-template) informed the team-policy adoption recipe, while [MISP Docker Lifecycle Manager](https://github.com/Tuxmint-Open-Source/misp-docker-lifecycle-manager) demonstrates the structured, safety-focused lifecycle approach that inspired this project's operational organization.

### Automation identity

The repository history also records work produced through [`hermes-speedboat`](https://github.com/hermes-speedboat), including commits authored as **Hermes Bitbull**.

These acknowledgements distinguish direct commit authorship from external inspiration.

## License

MIT. See [LICENCE](LICENCE).
