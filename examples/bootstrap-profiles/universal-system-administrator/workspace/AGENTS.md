# Workspace instructions

Example project/workspace instructions loaded when Hermes runs in `/workspace`.

- Keep generated files out of git unless requested.
- Prefer reproducible CLI commands.
- Resolve one topic folder with `hermes-workspace-manager` before task-related file operations.
- Treat `hermes-workspace-git` and `hermes-workspace-ansible` as specialized placement rules; do not create duplicate generic topic folders.
- For multi-host changes, prefer Ansible over per-host SSH.
- Always preserve the read-only-first discipline: investigate, then propose, then change only with authorization.
