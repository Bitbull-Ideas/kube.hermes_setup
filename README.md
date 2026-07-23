# kube.hermes_setup

Current release: **v2.0.1** (see [`VERSION`](VERSION) and [`CHANGELOG.md`](CHANGELOG.md)).

Production-oriented Kubernetes installer for a multi-container [Hermes Agent](https://github.com/nousresearch/hermes-agent) stack:

- **Hermes Agent** — API/gateway runtime (mandatory)
- **Hermes Dashboard** (optional) — administrative web dashboard
- **Hermes WebUI** (optional) — browser chat interface
- **Browserless Chromium** (optional) — internal real browser/CDP backend

The repository is template-driven and contains **no real hostnames, passwords, tokens, OAuth state, kubeconfig, or cluster-specific secrets**.

## Requirements

On the admin workstation:

- `kubectl`, `openssl`, `bash`, `python3`, `tar`
- Kubernetes context with namespace-scoped resource permissions
- Ingress controller compatible with standard Kubernetes Ingress

## Quick start

```bash
git clone https://github.com/Bitbull-Ideas/kube.hermes_setup.git
cd kube.hermes_setup
./configure.sh
```

The wizard asks about components, profiles, and credentials, then writes everything to `current_config/`:

| Path | Purpose |
|------|---------|
| `current_config/hermes.env` | Deployment settings (mode 600) |
| `current_config/bootstrap/config.yaml` | Native Hermes provider/model config |
| `current_config/bootstrap/SOUL.md` | Profile SOUL, memories, skills, cron |
| `current_config/artifacts/` | Rendered manifest, credentials, bootstrap archive |

`configure.sh` optionally hands off to `install.sh`. To configure without installing, pass `--no-install`.

## Lifecycle

### Configure

```bash
./configure.sh                    # interactive wizard
./configure.sh --from-answers     # replay from saved answers (after git pull)
./configure.sh --no-install       # configure only, skip installer
```

### Customize

After `configure.sh`, edit `current_config/hermes.env` to adjust settings before running the installer. All variables are documented in [`examples/hermes.env.example`](examples/hermes.env.example).

Common changes:

- **Hostnames**: Set `WEBUI_HOST` and `DASHBOARD_HOST` to your real FQDNs
- **Components**: `HERMES_DASHBOARD_ENABLED`, `HERMES_WEBUI_ENABLED`, `HERMES_BROWSER_ENABLED`
- **Model**: `MODEL_PROVIDER` and `MODEL_NAME` for the Hermes gateway
- **Bootstrap profile**: `HERMES_BOOTSTRAP_PROFILE` (`personal-assistant` or `universal-system-architect`)
- **Ansible**: `HERMES_ANSIBLE_SETUP=true` and `HERMES_ANSIBLE_VERSION=14.1.0`
- **Storage**: `HERMES_HOME_STORAGE_SIZE=10Gi`, `HERMES_WORKSPACE_STORAGE_SIZE=20Gi`
- **Images**: Pin tags in production instead of using `latest`

The native Hermes agent configuration is in `current_config/bootstrap/config.yaml`. Edit it directly to change provider, model, or gateway settings. Use `HERMES_BOOTSTRAP_MODE=missing` (default) to preserve later edits on the PVC; use `overwrite` only when the generated file should be authoritative.

### Install

```bash
./install.sh
```

The installer:

1. Loads `current_config/hermes.env` (or root `hermes.env`, or explicit `ENV_FILE`)
2. Generates credentials for blank values and applies them to Kubernetes Secrets
3. Captures generated values in `current_config/artifacts/generated-credentials.txt`
4. Renders the Kubernetes manifest
5. Creates/updates namespace, Secrets, bootstrap archive
6. Applies the manifest and waits for rollouts
7. Prints next steps

Generated credentials are written to `current_config/artifacts/generated-credentials.txt` (mode 600). Move values to a password manager and delete the file.

### Debug

```bash
./doctor.sh
```

Checks: cluster reachability, rollouts, internal service health, HOME/SSH/Ansible paths, WebUI agent wiring, Browserless/CDP connectivity, upload limits, optional ingress, and Codex OAuth state.

### Backup

```bash
./maintain.sh backup ./backups/hermes-$(date -u +%Y%m%dT%H%M%SZ).tgz
```

Archives `/opt/data` and `/workspace` PVCs, including OAuth state, skills, memories, sessions, and workspace files.

### Delete

```bash
kubectl delete namespace <namespace>
kubectl delete pvc -n <namespace> --all
```

Replace the namespace name. PVCs are **not** deleted with the namespace by default; delete them separately.

### Restore

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.tgz
./doctor.sh
```

Scales down deployments, clears both PVCs, restores the archive, and reapplies runtime ownership.

## Profiles

| Profile | Skills | Ansible | SSH | Requirements |
|---------|--------|---------|-----|-------------|
| `personal-assistant` | `markdown-pdf`, `hermes-workspace-manager` | false | false | profile `requirements.txt` |
| `universal-system-architect` | all five shared skills | true | true | profile `requirements.txt` + Ansible/cloud |

Override profile defaults by setting `HERMES_ANSIBLE_SETUP`, `HERMES_SSH_SETUP`, `HERMES_ADDON_REQUIREMENTS`, or `HERMES_ANSIBLE_VERSION` in `hermes.env`.

For a team policy skill, see the [team-policy template](https://github.com/Tuxmint-Open-Source/hermes-team-policy-template).

## Password rotation

```bash
./maintain.sh rotate-passwords --prompt          # interactive (default)
./maintain.sh rotate-passwords --generate         # random value, written to RENDER_DIR
./maintain.sh rotate-passwords --from-env         # CI/non-interactive
./maintain.sh rotate-browser-token                # Browserless token only
```

Production policy: minimum 14 characters with lower/upper/digit/symbol. Use `--lab` for lab systems.

## Security model

- Do not commit `hermes.env`, `current_config/`, `configuration_answers`, or `.rendered/`
- Browserless is ClusterIP only, token-protected, and NetworkPolicy-restricted
- Dashboard has internal BasicAuth
- WebUI password auth is enabled at startup (no remote first-password gate)
- Credential files are mode 600, Git-ignored
- API server keys shorter than 16 characters are replaced automatically

## Repository layout

```text
├── README.md, AGENTS.md, VERSION, LICENCE
├── configure.sh            # interactive/replay configuration generator
├── setup.sh                # thin wrapper for configure.sh
├── install.sh              # render/apply/upgrade installer
├── maintain.sh             # backup, restore, upgrade, password rotation
├── doctor.sh               # health checks and diagnostics
├── scripts/                # template and requirements helpers
├── tests/                  # profile, wizard, and render matrices
├── examples/
│   ├── hermes.env.example  # full variable reference with comments
│   ├── bootstrap-shared/   # shared skill and workspace sources
│   └── bootstrap-profiles/ # prebuilt profile definitions
├── manifests/              # Kubernetes manifest template
└── docs/                   # operations, security, troubleshooting, ansible, codex-auth
```

## Acknowledgements

- **Chris Rüttimann (`joe-speedboat`)** — project maintainer
- **Nicolas Eberle (`archham`)** — ideas, operational use cases, reusable skills

## License

MIT. See [LICENCE](LICENCE).