# Changelog

All notable changes to this project are documented in this file.

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
