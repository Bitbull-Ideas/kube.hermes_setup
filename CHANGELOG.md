# Changelog

All notable changes to this project are documented in this file.

## [v2.1.2] - 2026-08-05

### Fixed
- Minor documentation syntax fixes. [PR #57]

## [v2.1.1] - 2026-08-05

### Fixed

- Fixes `configure.sh` crashing with `HERMES_NPX_SETUP: unbound variable` when running the interactive wizard. The wizard did not resolve profile-owned variables — adds `apply_profile_defaults()` call after wizard questions so `HERMES_NPX_SETUP` (and any future profile-default variables) are populated from the selected profile's `defaults.conf` before writing the env file and composing bootstrap. [PR #56]

## [v2.1.0] - 2026-08-05

### Added

- Adds `HERMES_NPX_SETUP` toggle for npx/npm cache support. When enabled, the init job pre-creates the npm cache directory at `/opt/data/.npm` with correct `hermes:hermes` ownership, and `npm_config_yes=true` is injected into the agent container environment and the terminal profile hook. This prevents `npx`-based MCP servers and skill installers from blocking on interactive prompts or failing with `EACCES` when the agent runs subprocesses as the unprivileged runtime user.
- Adds `HERMES_PROFILE_DEFAULT_NPX_SETUP` to profile defaults: `true` for `universal-system-architect`, `false` for `personal-assistant`.
- Adds `HERMES_NPX_SETUP` validation in `install.sh`, `render_template.py`, and `configure.sh`.

### Changed

- Updates the init job script in `hermes.yaml.tpl` to seed the npm cache directory before the bootstrap chown step.
- Adds `npm_config_yes=true` to the agent deployment env vars in `hermes.yaml.tpl`.
- Adds `export npm_config_yes=true` to the terminal environment hook so login shells inherit the setting.
- Updates `examples/hermes.env.example` with the new `HERMES_NPX_SETUP` section.
- Updates the profile table in README to include the NPX column.

## [Unreleased]

### Added

- Adds encrypted full-rollback snapshots: repository-owned Kubernetes resources, application Secrets, normalized metadata, and the exact K3s server version are stored inside the age archive. `restore --full` recreates an absent Namespace and enforces K3s/version/Namespace gates by default; `--force` overrides all compatibility and targeting gates while retaining data-integrity and API failures.
- Adds `restore --full --dry-run` preflight output without Kubernetes or PVC changes.
- Adds configurable `HERMES_IMAGE_PULL_POLICY` with `IfNotPresent` default and explicit `Always` option.
- Adds isolated backup-helper regression tests and removes the setup-irrelevant remote logging reference.
- Adds declarative profile skill allowlists and profile environment defaults with operator overrides.
- Adds an interactive `configure.sh` wizard that stores the complete selected bootstrap and `hermes.env` under Git-ignored `current_config/`, then directs installer artifacts to `current_config/artifacts` during handoff.
- Adds independently selectable Dashboard, WebUI, and Browser components while keeping Agent mandatory.
- Adds versioned Ansible package installation through `HERMES_ANSIBLE_VERSION` whenever Ansible setup is enabled.
- Generates native Hermes `config.yaml` from the wizard and injects it through bootstrap into persistent `/opt/data/config.yaml`.

### Changed

- Integrates the generic workspace manager with the existing Git and Ansible workspace skills by defining specialized placement precedence and preventing duplicate topic folders.
- Replaces duplicate root/non-root SSH key installation recipes in the Ansible workspace skill with one idempotent account-aware example.
- Updates the bootstrap workspace instructions, SOUL profile, and README to describe the combined workspace lifecycle.
- Makes `personal-assistant` select `markdown-pdf` and `hermes-workspace-manager` without duplicating canonical skill sources, disable SSH setup by default, and activate its own addon requirements.
- Makes `universal-system-architect` select all shared skills, enable SSH setup, and activate its Ansible-oriented addon requirements by default.
- Condenses and reorganizes README around a documented `universal-system-architect` lifecycle: configure, customize `current_config`, install, debug, reconfigure, backup, delete/rebuild, and restore.
- Adds section headers and inline comments to `examples/hermes.env.example` for production readability.
- Keeps the shared `POST_SETUP.md` operator hint for optional post-install cron and delivery-channel configuration.
- Uses `configure.sh` as the canonical documented entrypoint while retaining `setup.sh` as a compatibility wrapper.

### Fixed

- Sets `HERMES_NIX_BUILD=1` for the current WebUI image so its Agent-source dependency installation remains compatible with recent Hermes Agent images that reject normal wheel/sdist builds; remove this compatibility setting after the upstream editable-install fix is released.
- Adds a mandatory live-acceptance QA contract for installer, Kubernetes, profile, credential, WebUI, Browserless, authentication, SSH, and Ansible changes; Agent-only or static-only evidence no longer qualifies for these scopes.
- Preserves existing Dashboard/WebUI, API server, and Browserless credentials during ordinary reinstalls when configuration values are blank; explicit maintenance commands remain the rotation path.
- Corrects the production walkthrough's bootstrap refresh, answer replay, credential retention, backup validation, namespace deletion, rebuild, and restore semantics.
- Makes `install.sh`, `doctor.sh`, and `maintain.sh` automatically discover wizard-generated `current_config/hermes.env` when no root `hermes.env` or explicit `ENV_FILE` is present.
- Preserves explicit `--from-env` password and browser-token rotation inputs when the active env file contains blank wizard placeholders.
- Clears internal profile-requirements state before each installer default-resolution pass so sourced or inherited state cannot alter custom requirements.
- Makes restore remove hidden as well as visible PVC entries and reapplies the configured runtime UID/GID instead of hard-coded `1000:1000` ownership.
- Adds image-specific Kubernetes security contexts: RuntimeDefault seccomp and disabled ServiceAccount-token automounting for all workloads; no privilege escalation for application containers; numeric non-root Browserless with all capabilities dropped.
- Adds a live-tested security exception for current Agent/Dashboard/WebUI root-start initialization and privileged init-container volume preparation.
- Moves Browserless token rotation from `kubectl --from-literal` process arguments to mode-restricted temporary files passed with `--from-file`, with cleanup traps.
- Adds cleanup traps for all installer and maintenance temporary Secret staging directories, including failed Kubernetes Secret-apply paths.
- Protects backup archives and generated SHA-256 checksum files with mode `0600`.
- Adds backup/restore cleanup traps and restores each enabled deployment to its original replica count after success or failure.
- Ensures the wizard offers configurable Agent, WebUI, and Browserless image references while retaining `latest` as the default.
- Ensures the wizard and installer never store or print plaintext credentials; authorized retrieval uses `./maintain.sh show-passwords`.
- Updates QA credential acceptance to require Secret-only storage and explicitly reject obsolete local credential-capture-file expectations.
- Replaces executable `ENV_FILE` sourcing in installer, maintenance, and diagnostics with a non-executing parser for quoted `KEY=value` assignments; unsafe shell environment controls are rejected.
- Changes the default model provider from `codex` to `openai-codex` across the wizard, installer defaults, example configuration, generated config tests, and maintainer documentation; provider-specific Codex OAuth instructions remain unchanged.
- Adds `maintain.sh show-passwords`, which retrieves and decodes the three Kubernetes credential Secrets for an authorized administrator; it does not write them to local files.
- Replaces installer and documentation-specific `kubectl` Secret extraction commands with the single `./maintain.sh show-passwords` administrator workflow.
- Uses native cryptographic password generation via `openssl rand -base64` for generated Dashboard/WebUI passwords; API keys and Browserless tokens remain hex secrets, and no MD5-based generation is used.
- Validates values crossing YAML and embedded-shell boundaries, including Kubernetes names, hosts, image references, resource sizes, numeric settings, paths, and control-character rejection.
- Corrects credential, render, and bootstrap artifact paths throughout the documentation for both wizard and manual installations.
- Corrects optional-component authentication and deployment claims, conditional SSH preparation, and duplicated operational guidance.
- Clears installer library mode before the wizard hands off to `install.sh`, so answering yes starts the deployment.
- Displays bootstrap profile choices on separate lines for terminal readability.
- Keeps the configuration wizard interactive when reusing `configuration_answers`: `y` pre-seeds saved non-secret answers, `n` uses built-in defaults, and blank passwords are never stored or offered as defaults.

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
