# kube.hermes_setup

Current release: **v2.0.1** (see [`VERSION`](VERSION) and [`CHANGELOG.md`](CHANGELOG.md)).

Production-oriented Kubernetes/K3s installer for a [Hermes Agent](https://github.com/nousresearch/hermes-agent) stack:

- **Hermes Agent** — mandatory API/gateway runtime
- **Hermes Dashboard** — optional administrative dashboard
- **Hermes WebUI** — optional browser chat interface
- **Browserless Chromium** — optional internal browser/CDP backend

The repository is template-driven. Deployment-specific configuration, generated credentials, OAuth state, kubeconfigs, and backups must remain outside Git.

## Requirements

On the admin workstation:

- `git`, `kubectl`, `openssl`, `bash`, `python3`, `tar`, and `sha256sum`
- a working Kubernetes context
- permission to manage the namespace and rendered Deployments, Services, Secrets, Jobs, PVCs, NetworkPolicies, Ingresses, and applicable Traefik CRDs
- when Dashboard or WebUI should be publicly reachable, an Ingress controller compatible with standard Kubernetes Ingress

## Production walkthrough: `universal-system-architect`

### 1. Configure without installing

```bash
git clone https://github.com/Bitbull-Ideas/kube.hermes_setup.git
cd kube.hermes_setup
./configure.sh --no-install
```

Choose the `universal-system-architect` profile. Select Dashboard, WebUI, and Browserless as required, enable Ansible, and keep bootstrap mode `missing` for the initial installation.

The wizard creates a profile-dependent tree like this:

```text
current_config/
├── hermes.env              # Kubernetes and installer settings
├── bootstrap/              # profile content seeded into persistent PVCs
│   ├── config.yaml         # native Hermes configuration
│   ├── SOUL.md
│   ├── memories/
│   ├── skills/
│   └── workspace/
└── artifacts/              # rendered manifest, archive, credentials
configuration_answers       # wizard answers for intentional replay
```

`current_config/` and `configuration_answers` are Git-ignored and can contain sensitive or personal data. The wizard writes `current_config/hermes.env` and `configuration_answers` with mode `0600`; plaintext credentials are not stored in either file.

### 2. Customize `current_config`

Edit Kubernetes and installer settings:

```bash
${EDITOR:-vi} current_config/hermes.env
```

Representative production changes:

```bash
WEBUI_HOST=hermes.example.com
DASHBOARD_HOST=hermes-admin.example.com
HERMES_BOOTSTRAP_PROFILE=universal-system-architect
HERMES_BOOTSTRAP_MODE=missing
HERMES_ANSIBLE_SETUP=true
HERMES_ANSIBLE_VERSION=14.1.0
HERMES_HOME_STORAGE_SIZE=20Gi
HERMES_WORKSPACE_STORAGE_SIZE=50Gi

# Pin reviewed image tags in production.
HERMES_AGENT_IMAGE=nousresearch/hermes-agent:CHANGE_ME
HERMES_WEBUI_IMAGE=ghcr.io/nesquena/hermes-webui:CHANGE_ME
HERMES_BROWSER_IMAGE=ghcr.io/browserless/chromium:CHANGE_ME
```

Use [`examples/hermes.env.example`](examples/hermes.env.example) as the complete commented variable reference. Do not copy it over the generated file; edit only the generated values you need.

Edit native Hermes behavior separately:

```bash
${EDITOR:-vi} current_config/bootstrap/config.yaml
```

Example structure:

```yaml
provider: codex
model: gpt-5.6-luna
agent:
  verify_on_stop: false
terminal:
  cwd: /workspace
display:
  tool_progress: all
gateway:
  host: 0.0.0.0
  port: 8642
```

This file becomes persistent `/opt/data/config.yaml` through the bootstrap init job. You may also customize `current_config/bootstrap/SOUL.md`, memories, selected skills, and workspace seed files before the first installation.

Bootstrap modes:

- `missing` copies only files absent from the PVC. It applies pre-install customization but does not update a file that already exists after installation.
- `overwrite` replaces same-path files and merges source directories on the next installer run. Destination-only files remain until removed separately. Use it deliberately, verify the result, then return to `missing`.
- `disabled` skips bootstrap content.

### 3. Install

For the default generated path:

```bash
./install.sh
```

The installer automatically discovers `current_config/hermes.env`. An explicit path also works:

```bash
ENV_FILE=./current_config/hermes.env ./install.sh
```

It validates settings, renders the manifest, creates the namespace and Secrets, applies resources, runs the bootstrap job, and waits for rollouts.

`install.sh` applies credentials directly through Kubernetes Secrets and does not create a local credential file:

```text
Kubernetes Secret `hermes-dashboard-auth` (extract with the command printed by `install.sh`)
```

On the first installation, missing credentials are generated directly into Kubernetes Secrets. On later installations, blank values reuse existing Kubernetes Secrets; explicit values override them. `install.sh` does not print or store plaintext credentials. Use the printed `kubectl` extraction command or `maintain.sh` for deliberate rotation.

If using Codex, load the generated environment and complete OAuth pairing in an interactive shell:

```bash
set -a
source current_config/hermes.env
set +a
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
# Run inside the pod:
hermes model
```

OAuth state persists at `/opt/data/auth.json` on the home PVC.

### 4. Debug and inspect

```bash
set -a
source current_config/hermes.env
set +a
./maintain.sh status
./doctor.sh
kubectl -n "$HERMES_NAMESPACE" get pods,svc,ingress,networkpolicy -o wide
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-agent
```

Use component logs only when that component is enabled:

```bash
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-dashboard
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-webui
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-browser
```

See [`docs/qa.md`](docs/qa.md) for the mandatory live acceptance matrix, [`docs/troubleshooting.md`](docs/troubleshooting.md), [`docs/operations.md`](docs/operations.md), and [`docs/ansible.md`](docs/ansible.md).

### 5. Reconfigure

Edit deployment settings and rerun the installer:

```bash
${EDITOR:-vi} current_config/hermes.env
./install.sh
./doctor.sh
```

With `HERMES_BOOTSTRAP_MODE=missing`, edits to `current_config/bootstrap/` do not replace files already present on the PVC. To replace same-path files and merge generated directories, set `HERMES_BOOTSTRAP_MODE=overwrite`, run `./install.sh`, verify the resulting PVC content, and return the setting to `missing`. Files present only on the PVC remain until removed separately.

Do **not** replay answers for ordinary changes. `./configure.sh --from-answers` rebuilds wizard-owned `current_config/` and discards manual edits made after the wizard. Use replay only when you intentionally want to regenerate configuration, then reapply required customization before installing.

### 6. Backup

Before destructive operations:

```bash
mkdir -p backups
backup="./backups/hermes-$(date -u +%Y%m%dT%H%M%SZ).tgz"
./maintain.sh backup "$backup"
# maintain.sh creates and protects the matching .sha256 file.
tar -tzf "$backup" >/dev/null
sha256sum -c "$backup.sha256"
stat -c '%a %n' "$backup" "$backup.sha256"  # both must be 600
```

The archive contains both PVC filesystems:

```text
/opt/data
/workspace
```

It can include OAuth state, sessions, skills, memories, WebUI state, and workspace data. It does **not** contain Kubernetes Secrets. Before namespace deletion, retain required credential values separately. Store backups encrypted and restrict access.

### 7. Delete and rebuild

> **Destructive:** deleting the namespace deletes its Deployments, Services, Secrets, Ingresses, Jobs, and PVC objects. Underlying PV data behavior depends on the storage class and PV reclaim policy; never rely on retained storage. Verify the backup first.

Keep the repository, `current_config/`, `configuration_answers`, backup, checksum file, and required credentials. With the generated environment loaded as shown above:

```bash
kubectl delete namespace "$HERMES_NAMESPACE"
```

Before reinstalling, retain the credential values separately. If the recreated namespace has no Secrets, the installer generates new values for blank settings; if Secrets are retained, blank settings reuse them. Explicitly restore known values in `current_config/hermes.env` when you require deterministic credentials across a destructive rebuild. Keep the file mode `0600`. Depending on the storage backend and reclaim policy, the mounted volumes may be fresh or may contain retained data; restore clears their mounted contents before extracting the backup.

```bash
chmod 600 current_config/hermes.env
./install.sh
```

### 8. Restore

Restore only after `install.sh` has recreated the namespace, Deployments, and PVCs:

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.tgz
./doctor.sh
```

Restore scales the enabled write-heavy deployments down, clears visible and hidden entries on both PVCs, extracts the archive, reapplies `HERMES_RUNTIME_UID:HERMES_RUNTIME_GID`, removes the helper Pod, and restores each deployment's original desired replica count. If any restore step fails, the cleanup path removes the helper Pod and attempts to restore those original counts.

## Profiles

| Profile | Skills | Ansible | SSH | Addon requirements |
|---|---|---|---|---|
| `personal-assistant` | `markdown-pdf`, `hermes-workspace-manager` | disabled | disabled | profile requirements |
| `universal-system-architect` | all shared skills | enabled | enabled | Ansible/cloud requirements |

Explicit `HERMES_ANSIBLE_SETUP`, `HERMES_SSH_SETUP`, `HERMES_ADDON_REQUIREMENTS`, and `HERMES_ANSIBLE_VERSION` values override profile defaults.

## Common operations

```bash
./maintain.sh status
./maintain.sh restart
./maintain.sh upgrade
./maintain.sh rotate-passwords --prompt
./maintain.sh rotate-passwords --generate
./maintain.sh rotate-passwords --from-env
./maintain.sh rotate-browser-token
```

`setup.sh` remains a compatibility wrapper around `configure.sh`; new documentation uses `configure.sh` directly.

## Security essentials

- Never commit `hermes.env`, `current_config/`, `configuration_answers`, `.rendered/`, backups, kubeconfigs, OAuth files, passwords, or tokens.
- Browserless is internal-only, token-protected, and NetworkPolicy-restricted.
- Dashboard and WebUI use the shared application password Secret.
- Credential files use mode `0600` and should be removed after transfer to a password manager.
- Terminate TLS at the Ingress controller; this repository references but does not issue certificates.

See [`docs/security.md`](docs/security.md).

## Repository layout

```text
├── README.md, AGENTS.md, VERSION, LICENCE
├── configure.sh            # canonical interactive/replay configurator
├── setup.sh                # compatibility wrapper for configure.sh
├── install.sh              # render and apply the stack
├── maintain.sh             # status, restart, backup/restore, rotation
├── doctor.sh               # runtime diagnostics
├── examples/
│   ├── hermes.env.example  # complete commented variable reference
│   ├── bootstrap-shared/   # canonical shared bootstrap sources
│   └── bootstrap-profiles/ # profile definitions and requirements
├── manifests/              # Kubernetes manifest template
├── scripts/                # rendering and requirements helpers
├── tests/                  # profile, configurator, and matrix tests
└── docs/                   # focused operations and troubleshooting guides
```

## Acknowledgements

- **[Chris Rüttimann (`joe-speedboat`)](https://github.com/joe-speedboat)** — project maintainer.
- **[Nicolas Eberle (`archham`)](https://github.com/archham)** — operational ideas, use cases, and reusable-skill inspiration.
- **[`hermes-speedboat`](https://github.com/hermes-speedboat)** — automation identity represented in repository history.

## License

MIT. See [LICENCE](LICENCE).
