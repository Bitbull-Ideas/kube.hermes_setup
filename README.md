# kube.hermes_setup

Current release: **v2.3.0** (see [`VERSION`](VERSION) and [`CHANGELOG.md`](CHANGELOG.md)).

Production-oriented Kubernetes/K3s installer for a [Hermes Agent](https://github.com/nousresearch/hermes-agent) stack:

- **Hermes Agent** — mandatory API/gateway runtime
- **Hermes Dashboard** — optional administrative dashboard
- **Hermes WebUI** — optional browser chat interface
- **Browserless Chromium** — optional internal browser/CDP backend

The repository is template-driven. Deployment-specific configuration, credentials, OAuth state, kubeconfigs, rendered artifacts, and backups must remain outside Git.

## Requirements

The administrative workstation needs:

- `git`, `kubectl`, `age`, `openssl`, `bash`, `python3`, GNU `tar`, `gzip`, and `sha256sum`
- a working Kubernetes context
- permission to manage the target namespace and rendered resources
- an Ingress controller when Dashboard or WebUI should be publicly reachable

## Quick start

```bash
git clone https://github.com/Bitbull-Ideas/kube.hermes_setup.git
cd kube.hermes_setup
./configure.sh --no-install
```

The configurator writes Git-ignored deployment files under `current_config/`. Review them before installation. Use [`examples/hermes.env.example`](examples/hermes.env.example) as the complete configuration-variable reference.

For production use, read the security, operations, and QA guides before continuing:

```bash
./install.sh
./doctor.sh
```

## Bootstrap profiles

- `personal-assistant`
- `universal-system-architect`
- `universal-system-administrator`

Profiles seed the persistent Hermes home and workspace with a curated identity, configuration, skills, and optional tooling. Explicit installer settings override profile defaults.

## Documentation

| Guide | Purpose |
|---|---|
| [`docs/operations.md`](docs/operations.md) | Installation lifecycle, maintenance, upgrades, backup/restore, credentials, bootstrap behavior, and persistent tooling |
| [`docs/security.md`](docs/security.md) | Secrets, authentication, TLS, container security, Browserless/CDP controls, and backup protection |
| [`docs/qa.md`](docs/qa.md) | Required local, render, cluster, reinstall, backup, credential, and runtime acceptance checks |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Common deployment, PVC, ingress, WebUI, Browserless, Dashboard, and authentication failures |
| [`docs/pvc-and-containers.md`](docs/pvc-and-containers.md) | PVC layout, container mounts, environment variables, and persistence boundaries |
| [`docs/codex-auth.md`](docs/codex-auth.md) | OpenAI Codex OAuth pairing and persistence |
| [`docs/ansible.md`](docs/ansible.md) | Persistent Ansible environment, SSH integration, roles, and collections |

Additional references:

- [`examples/hermes.env.example`](examples/hermes.env.example) — complete installer variable reference
- [`CHANGELOG.md`](CHANGELOG.md) — release history
- [`AGENTS.md`](AGENTS.md) — maintainer and validation guidance

## Main commands

| Command | Purpose |
|---|---|
| `./configure.sh` | Create or intentionally regenerate local configuration |
| `./install.sh` | Validate, render, apply, and verify the stack |
| `./maintain.sh` | Inspect and maintain an installation |
| `./doctor.sh` | Run deployment diagnostics |

`setup.sh` remains a compatibility wrapper around `configure.sh`.

## Acknowledgements

- **[Chris Rüttimann (`joe-speedboat`)](https://github.com/joe-speedboat)** — project maintainer
- **[Nicolas Eberle (`archham`)](https://github.com/archham)** — operational ideas, use cases, and reusable-skill inspiration
- **[Hermes Agent (`hermes-speedboat`)](https://github.com/hermes-speedboat)** — automation identity represented in repository history

## License

MIT. See [LICENCE](LICENCE).
