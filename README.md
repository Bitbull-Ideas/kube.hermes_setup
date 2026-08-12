# kube.hermes_setup

Current release: **v2.2.2** (see [`VERSION`](VERSION) and [`CHANGELOG.md`](CHANGELOG.md)).

Production-oriented Kubernetes/K3s installer for a [Hermes Agent](https://github.com/nousresearch/hermes-agent) stack:

- **Hermes Agent** — mandatory API/gateway runtime
- **Hermes Dashboard** — optional administrative dashboard
- **Hermes WebUI** — optional browser chat interface
- **Browserless Chromium** — optional internal browser/CDP backend

The repository is template-driven. Deployment-specific configuration, generated credentials, OAuth state, kubeconfigs, and backups must remain outside Git.

## Requirements

On the admin workstation:

- `git`, `kubectl`, `age`, `openssl`, `bash`, `python3`, `tar`, and `sha256sum`
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
provider: openai-codex
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

`install.sh` applies credentials directly through Kubernetes Secrets and does not create a local credential file. Use the administrator-only maintenance command when the values are needed:

```text
./maintain.sh show-passwords
```

On the first installation, missing credentials are generated directly into Kubernetes Secrets. On later installations, blank values reuse existing Kubernetes Secrets; explicit values override them. `install.sh` does not print or store plaintext credentials. Use `./maintain.sh show-passwords` when an authorized administrator needs to retrieve them, and use the rotation commands for deliberate changes.

If using Codex, complete OAuth pairing in an interactive shell. Pass the namespace explicitly; do not source the generated environment file:

```bash
kubectl -n <namespace> exec -it deploy/hermes-agent -- /bin/bash
# Run inside the pod:
hermes model
```

OAuth state persists at `/opt/data/auth.json` on the home PVC.

### 4. Debug and inspect

```bash
ENV_FILE=./current_config/hermes.env ./maintain.sh status
ENV_FILE=./current_config/hermes.env ./maintain.sh show-passwords
ENV_FILE=./current_config/hermes.env ./doctor.sh
kubectl -n <namespace> get pods,svc,ingress,networkpolicy -o wide
kubectl -n <namespace> logs deploy/hermes-agent
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
backup="./backups/hermes-$(date -u +%Y%m%dT%H%M%SZ).age"
./maintain.sh backup "$backup"
# maintain.sh creates and protects the matching .sha256 file.
sha256sum -c "$backup.sha256"
stat -c '%a %n' "$backup" "$backup.sha256"  # both must be 600
```

The encrypted archive contains both PVC filesystems, local reconstruction metadata, and (for full rollback) a normalized snapshot of the repository-owned Kubernetes resources:

```text
opt/data
workspace
metadata/hermes.env
metadata/configuration_answers
metadata/bootstrap/
metadata/kubernetes/cluster-version.txt
metadata/kubernetes/resources.json
```

`resources.json` contains the Namespace, Hermes PVCs, Deployments, Services, Jobs, Ingresses, NetworkPolicies, Middleware, ServiceAccounts, and the four repository-owned application Secrets. It is inside the age-encrypted archive; Secret values are never printed. Live-cluster metadata such as UIDs, resource versions, managed fields, creation timestamps, and status are removed before storage.

### 7. Delete and rebuild

> **Destructive:** deleting the namespace deletes its Deployments, Services, Secrets, Ingresses, Jobs, and PVC objects. Underlying PV data behavior depends on the storage class and PV reclaim policy; never rely on retained storage. Verify the backup first.

Keep the repository, encrypted backup, checksum file, and passphrase separately. If the namespace is deleted, do not reinstall first when a matching full snapshot exists. Use a dry-run, then restore the Namespace, resources, Secrets, and PVC payload directly:

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.age \
  --full --dry-run --password-file /secure/hermes-backup.pass
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.age \
  --full --password-file /secure/hermes-backup.pass
./doctor.sh
```

The full restore applies the Namespace recorded in the backup. Without `--force`, the API server must be detectable as K3s with the exact version recorded in the backup and `HERMES_NAMESPACE` must match. With `--force`, all three compatibility/targeting gates are overridden; malformed, undecryptable, or unappliable data still fails.

### 8. Restore

A normal restore requires `install.sh` to have recreated the Namespace, Deployments, and PVCs and restores only the encrypted `opt/data` and `workspace` payload:

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.age
./doctor.sh
```

For a deleted Namespace or installation, use `restore --full` as described above. It applies only the normalized repository-owned resources from the encrypted snapshot and never applies local configuration files automatically.

```bash
./maintain.sh extract ./backups/hermes-YYYYmmddTHHMMSSZ.age \
  --output-dir ./recovery \
  --component bootstrap
```

Supported components are `data`, `config`, `bootstrap`, and `full`. The output directory must be new or empty. Use `--dry-run` to decrypt and validate the archive and show what would be extracted without writing files. Password input supports `--password-prompt`, `--password-stdin`, and `--password-file PATH`. The `full` extraction includes the encrypted snapshot metadata, including normalized Kubernetes resources and application Secret data; use it only in a mode-0700 recovery directory. Full rollback should normally use `restore --full` rather than manually applying extracted resources.

## Profiles

| Profile | Skills | NPX | Ansible | SSH | Addon requirements |
|---|---|---|---|---|---|
| `personal-assistant` | `markdown-pdf`, `hermes-workspace-manager`, `hermes-log-watchdog`, `coaching-recurring-patterns` | disabled | disabled | disabled | profile requirements |
| `universal-system-architect` | all shared skills | enabled | enabled | enabled | Ansible/cloud requirements |
| `universal-system-administrator` | all shared skills + 3 profile-specific skills | enabled | enabled | disabled | Ansible requirements |

Explicit `HERMES_NPX_SETUP`, `HERMES_ANSIBLE_SETUP`, `HERMES_SSH_SETUP`, `HERMES_ADDON_REQUIREMENTS`, and `HERMES_ANSIBLE_VERSION` values override profile defaults.

### Profile default resolution

Variables that belong to a profile (`HERMES_SSH_SETUP`, `HERMES_ANSIBLE_SETUP`, `HERMES_NPX_SETUP`) are resolved in this order:

1. **Explicit env/wizard answer** — if the user sets the variable in `hermes.env` or answers the wizard question, that value wins.
2. **Profile default** — if the variable is still unset after the wizard (user pressed Enter), `apply_profile_defaults()` fills it from the selected profile's `defaults.conf` (e.g. `HERMES_PROFILE_DEFAULT_NPX_SETUP`).
3. **Installer fallback** — `install.sh::prepare_defaults()` applies `:-false` as a last-resort default if neither the profile nor the user provided a value.

Variables without a profile default (e.g. `HERMES_ADDON_PYTHON_VERSION`) use only step 1 and the installer's hardcoded fallback (`:-3.13` in `install.sh` line 292). There is no profile-specific Python version.

In practice this means:

| Variable | Profile-owned? | Profile source | Installer fallback |
|----------|---------------|----------------|--------------------|
| `HERMES_SSH_SETUP` | Yes | `HERMES_PROFILE_DEFAULT_SSH_SETUP` | `:-true` |
| `HERMES_ANSIBLE_SETUP` | Yes | `HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP` | `:-false` |
| `HERMES_NPX_SETUP` | Yes | `HERMES_PROFILE_DEFAULT_NPX_SETUP` | `:-false` |
| `HERMES_ADDON_PYTHON_VERSION` | No | (none) | `:-3.13` |

The configure.sh wizard follows the same chain: answers the user gave are saved to `configuration_answers`, blank inputs leave the variable unset, and the subsequent `apply_profile_defaults()` call fills profile-owned variables from the selected profile before the env file is written.

Skill metadata may list related skills. In this repository, a related skill is **bundled** only when its directory exists under `examples/bootstrap-shared/skills/`. A reference such as `hermes-agent`, `github-auth`, or `github-pr-workflow` is an **external-runtime** or **optional-reference** dependency and is not copied by this setup. The profile's `skills.txt` file is the authoritative installation allowlist.

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

### scripts/

| Script | Purpose |
|--------|---------|
| `render_template.py` | Reads the Jinja-style template (`manifests/hermes.yaml.tpl`) and environment variables, validates all values at the YAML/shell boundary (control characters, DNS names, booleans, image references), and writes the final multi-document Kubernetes manifest. Called by `install.sh`. |
| `prepare_requirements.py` | Merges profile `requirements.txt` with the explicitly configured Ansible version. Replaces bare `ansible` entries with the pinned `ansible==VERSION` line so the addon pip install is deterministic. |
| `age_passphrase.py` | Manages age-encryption passphrase lifecycle for `maintain.sh backup`/`restore`: prompt, stdin, or file-based delivery with mode-0600 validation. |
| `kube_snapshot.py` | Captures a normalized snapshot of repository-owned Kubernetes resources (Namespace, PVCs, Deployments, Secrets, Services, Ingresses, NetworkPolicies, Jobs) for encrypted backup metadata. Used by `maintain.sh backup --full`. |

### tests/

| Test | Scope | What it checks |
|------|-------|----------------|
| `profile-composition.sh` | Bootstrap profiles | Skill allowlists, shared vs. profile-specific file layout, SSH/Ansible/NPX flag propagation, operator-variable overrides, custom `ANSIBLE_CONFIG` preservation. Runs `apply_profile_defaults()` + `compose_profile_bootstrap()` in matching sequences. |
| `configure.sh` | Wizard artifacts | Interactive and `--from-answers` generation: env file mode 0600, credential absence from answers, correct `HERMES_*` values per profile, bootstrap config.yaml contract, prepared archive content, answer reuse/replay, replay-security against unowned directories. |
| `matrix.sh` | Manifest rendering | All 8 optional-component combinations (Dash/WebUI/Browser on/off), 16 profile/Ansible/requirements combinations, injection-attack rejection (multiline YAML, invalid namespace). Each case renders the full manifest and validates resource presence/absence with Python + PyYAML. |
| `backup.sh` | Backup/restore lifecycle | Encrypted archive creation, passphrase delivery, checksum validation, traversal/link/type rejection, dry-run restore, K3s-version/namespace policy enforcement, force override behavior, and malformed-archive handling. |
| `credentials.sh` | Secret lifecycle | Explicit-vs-generated-vs-reused credential precedence, malformed/empty/missing Secret detection, weak-key rejection, and cross-credential boundary tests (Dashboard vs API vs Browserless). |
| `qa-contract.sh` | Live-deployment contract | Shared conventions and assertion style used by all tests; documents the mandatory-live-acceptance policy referenced by `docs/qa.md`. |

### docs/

| Document | Content |
|----------|---------|
| `operations.md` | Day-2 operations: status, restart, upgrade, backup/restore/extract, bootstrap configuration lifecycle, credential management, password rotation, Browser token rotation, Codex re-auth, WebUI CDP setup, Browserless resource knobs, resource sizing, persistent Python addon packages, persistent HOME and SSH, and NPX/Node.js support. |
| `qa.md` | Mandatory live-acceptance policy: test evidence requirements, minimum component matrix (agent-only, dashboard, webui, browser, full, reinstall, failure), backup acceptance, credential acceptance, and quality-rule labelling (static/local, render/schema, live/cluster, runtime/acceptance). |
| `security.md` | Security posture: secrets policy, container security contexts, Browserless/CDP lockdown, authentication layers, TLS termination, backup encryption, password policy, credential storage, WebUI password bootstrap, upload sizing, API key length, and bootstrap data sensitivity. |
| `troubleshooting.md` | Common failure patterns: init job failures, PVC issues, rollout stalls, ingress/connectivity, Browserless/CDP problems, WebUI authentication, and Codex OAuth pairing issues. |
| `codex-auth.md` | Step-by-step OpenAI Codex OAuth pairing: `hermes model` execution, auth.json creation, backup-only persistence recommendation, and recovery from lost OAuth state. |
| `ansible.md` | Ansible integration: addon-venv activation, collection bake-off, inventory construction, Ansible-core overrides, persistent known_hosts, and SSH config templates. |

## Acknowledgements

- **[Chris Rüttimann (`joe-speedboat`)](https://github.com/joe-speedboat)** — project maintainer.
- **[Nicolas Eberle (`archham`)](https://github.com/archham)** — operational ideas, use cases, and reusable-skill inspiration.
- **[Hermes Agent (`hermes-speedboat`)](https://github.com/hermes-speedboat)** — automation identity represented in repository history.

## License

MIT. See [LICENCE](LICENCE).
