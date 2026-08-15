# Workspace instructions

Example project/workspace instructions loaded when Hermes runs in `/workspace`.

- Keep generated files out of git unless requested.
- Prefer reproducible CLI commands.
- Resolve one topic folder with `hermes-workspace-manager` before task-related file operations.
- Treat `hermes-workspace-git` and `hermes-workspace-ansible` as specialized placement rules; do not create duplicate generic topic folders.
- For multi-host changes, prefer Ansible over per-host SSH.
- Apply the read-only-first, propose-before-change discipline to managed Linux targets reached through SSH, Ansible, inventory, or another explicit target connection.
- Routine self-maintenance of the active Hermes runtime under `$HERMES_HOME` (normally `/opt/data`) and `/workspace` may be performed directly when requested; do not require managed-target `/srv/backup` or `/CHANGES.md` procedures for those container/PVC files.
- Treat Kubernetes resources, Secrets, access, availability, and PVC lifecycle as installer/cluster administration, not routine runtime-file maintenance.
