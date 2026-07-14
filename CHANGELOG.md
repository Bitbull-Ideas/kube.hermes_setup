# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

## [v1.2.2] - 2026-07-13

### Added

- Extends persistent HOME/XDG, SSH, addon Python, and Ansible runtime parity to the Dashboard container, matching Agent and WebUI behavior.
- Extends `doctor.sh` to validate HOME/XDG, `ANSIBLE_CONFIG`, SSH key permissions, addon Python, and `ansible localhost -m ping` across Agent, Dashboard, and WebUI.

### Changed

- Simplifies authentication by removing the optional Traefik middleware BasicAuth layer; Dashboard and WebUI application auth remain configured by default.
- Changes the default model to `gpt-5.6-luna`.
- Makes persistent `HOME=/opt/data` and XDG directories the fixed default for Agent, Dashboard, and WebUI instead of a configurable `HERMES_HOME_AS_HOME` toggle.
- Simplifies `maintain.sh rotate-passwords` to rotate the shared Dashboard/WebUI password only.
- Keeps operator-managed `config.yaml` intact while replacing only the untouched Agent image default config during init.
- Sets the Browserless default concurrency to `BROWSER_CONCURRENT=2` and strengthens CDP reachability checks.
- Documents and persists the Browserless CDP URL in the shared `/opt/data/.env` while retaining Secret-backed `BROWSER_CDP_URL` injection in Agent, Dashboard, and WebUI.

## [v1.2.1] - 2026-07-11

### Added

- Sets persistent HOME/XDG and UTF-8 locale for Python addon CLIs in WebUI so uv-managed Ansible can run there.
- Adds a uv-managed persistent addon Python runtime under `/opt/data/uv` so addon CLIs like Ansible work from both Agent and WebUI containers.
- Ensures `/workspace/ansible` is created by default, sets `ANSIBLE_CONFIG`, and documents container mount locations plus visible roles/collections install paths.
- Adds persistent Ansible control-node examples and documentation using the addon venv, workspace bootstrap, and persistent SSH setup.
- Adds persistent Agent HOME/XDG and SSH keypair setup with safe `/opt/data/.ssh` permissions and missing-only key generation.
- Adds opt-in persistent Python addon venv support via `HERMES_ADDON_REQUIREMENTS` and `HERMES_ADDON_VENV`, including manual install documentation.
- Replaces the placeholder bootstrap skill with a reusable `markdown-pdf` skill, including a pip-only renderer, editorial CSS theme, and container-focused verification notes.
- Adds example addon requirements for the bundled `markdown-pdf` workflow and `pyvim`.

### Changed

- Removes duplicate Markdown PDF dependency entries from the example bootstrap requirements file.

## [v1.2.0] - 2026-07-11

### Changed

- Tunes installer and example resource defaults for small K3s/lab deployments: 100m CPU requests, 1 CPU limits, 256Mi Agent/WebUI memory requests, 96Mi Dashboard memory request, 128Mi Browserless memory request, and 1Gi memory limits.
- Expands the bundled bootstrap `SOUL.md` browser/CDP guidance for direct CDP usage, screenshot validation, and clear fallback behavior when the default CDP endpoint is unavailable.

## [v1.1.0] - 2026-07-10

### Added

- Adds opt-in bootstrap support through `HERMES_BOOTSTRAP_DIR` for `SOUL.md`, durable memories, skills, plugins, cron configuration, workspace files, and optional authentication state.
- Adds a reusable universal systems-architect bootstrap profile covering platform operations, architecture, research, QA, and software development.
- Exposes the mounted workspace through the Dashboard file browser and configures safe write roots for Agent, Dashboard, and WebUI.

### Changed

- Raises the default WebUI upload limit for large documents.
- Tunes public-example resource requests and limits for practical lab deployments.

### Upgrade notes

- Bootstrap is opt-in. Use `HERMES_BOOTSTRAP_MODE=missing` for normal upgrades.
- `HERMES_BOOTSTRAP_MODE=overwrite` replaces bootstrap-managed data and should be used only after review.

## [v1.0.0] - 2026-07-09

### Added

- Initial public release of the production-oriented Kubernetes/K3s installer for the Hermes Agent stack.
- Adds template-driven manifests for Hermes Agent Gateway, Hermes Dashboard, Hermes WebUI, and internal Browserless Chromium/CDP support.
- Provides `install.sh` for repeatable namespace-scoped installation, manifest rendering, secret creation, rollout waits, and upgrades.
- Provides `maintain.sh` for status checks, backup/restore, restart, upgrade, password rotation, and Browserless token rotation.
- Provides `doctor.sh` health checks for Kubernetes resources, service readiness, ingress access, WebUI agent wiring, Browserless/CDP connectivity, NetworkPolicy reachability, and Codex OAuth state.
- Documents operations, security, troubleshooting, Codex OAuth pairing, and agent maintainer workflows.
- Includes safe public examples and templates without real hostnames, passwords, tokens, OAuth state, kubeconfig, or generated secrets.
