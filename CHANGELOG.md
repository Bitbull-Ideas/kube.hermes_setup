# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- Adds the `hermes-workspace-manager` bootstrap skill for topic-folder resolution, artifact containment, continuity, and explicit archival.
- Adds declarative profile skill allowlists and profile environment defaults with operator overrides.
- Adds an interactive `configure.sh` wizard that stores the complete selected bootstrap, `hermes.env`, and generated artifacts under the Git-ignored `current_config/` directory before handing off to `install.sh`.
- Adds independently selectable Dashboard, WebUI, and Browser components while keeping Agent mandatory.
- Adds versioned Ansible package installation through `HERMES_ANSIBLE_VERSION` whenever Ansible setup is enabled.
- Generates native Hermes `config.yaml` from the wizard and injects it through bootstrap into persistent `/opt/data/config.yaml`.

### Changed

- Integrates the generic workspace manager with the existing Git and Ansible workspace skills by defining specialized placement precedence and preventing duplicate topic folders.
- Updates the bootstrap workspace instructions, SOUL profile, README, and post-setup guidance to describe the combined workspace lifecycle.
- Makes `personal-assistant` select `markdown-pdf` and `hermes-workspace-manager` without duplicating canonical skill sources, disable SSH setup by default, and activate its own addon requirements.
- Makes `universal-system-architect` select all shared skills, enable SSH setup, and activate its Ansible-oriented addon requirements by default.

### Fixed

- Clears installer library mode before the wizard hands off to `install.sh`, so answering yes starts the deployment.
- Displays bootstrap profile choices on separate lines for terminal readability.
- Reports the actual configured credential-capture path in the installer summary.
- Removes the temporary composed-profile stage after copying it into the canonical generated bootstrap directory.
- Makes `HERMES_ANSIBLE_SETUP=false` exclude a profile-provided Ansible workspace from generated bootstrap content on fresh deployments.
- Preserves an explicit `HERMES_ANSIBLE_CONFIG` override and makes diagnostics validate the configured path rather than requiring the default path.

## [v2.0.1] - 2026-07-20

### Fixed

- Makes the Markdown PDF skill honor `--no-cover` when using the default `fpdf2` backend and corrects its no-cover usage example.
- Neutralizes the reusable team-policy post-setup recipe by replacing repository-specific organization values with explicit `ASK_USER_AND_CHANGE` markers.
- Requires Hermes to resolve every organization marker with the requesting user before installing the adapted policy.

### Changed

- Raises every bundled bootstrap skill version to `2.0.1` for the v2.0.1 release.

## [v2.0.0] - 2026-07-20

### Added

- Adds `VERSION` as the release-version source of truth.
- Adds bootstrap skills for general Git workspace lifecycle, Ansible-native workspace lifecycle, and least-privilege public GitHub pull-request access.
- Adds concise post-setup recipes for activating bootstrap skills and adapting a mandatory Hermes team policy.
- Adds contributor and inspiration acknowledgements, including Nicolas Eberle's structured operational use cases and reusable Hermes policy-skill work.

### Changed

- Renames the Ansible workspace skill to `hermes-workspace-ansible` for consistent workspace-skill naming.
- Raises every bundled bootstrap skill version to `2.0.0` for the v2 release line.
- Sets Browserless concurrency to four with a 30-second session timeout and persists/verifies CDP configuration across Hermes components.

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
- Sets the Browserless default concurrency to `BROWSER_CONCURRENT=4` and session timeout to `BROWSER_TIMEOUT_MS=30000`.
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
