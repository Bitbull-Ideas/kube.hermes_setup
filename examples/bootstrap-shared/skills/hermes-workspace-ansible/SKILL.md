---
name: hermes-workspace-ansible
description: Use when creating, modifying, testing, reviewing, or cleaning up Ansible automation in a workspace that contains an ansible/ directory. Keep all Ansible work contained there, record Python and collection dependencies, use the authorized SSH identity safely, and offer consent-based archival of completed project files.
version: 2.0.1
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [ansible, workspace, ssh, cleanup, collaboration]
    related_skills: [hermes-workspace-manager, hermes-workspace-git]
---

# Hermes Ansible Workspace

## Overview

Act as a considerate team member in workspaces that provide an `ansible/` directory. Keep Ansible source, dependencies, generated artifacts, and task-specific scratch work inside that directory while work is active. Preserve existing conventions, do not disturb unrelated automation, and make completed work easy to review and archive. This skill is the specialized Ansible placement layer for `hermes-workspace-manager`: resolve `<workspace>/ansible` itself or one established project/subtree beneath it as the topic scope, according to the existing layout, and do not create a duplicate generic topic folder.

Use `<workspace>` for the active workspace supplied by Hermes. The active paths are:

- Ansible workspace: `<workspace>/ansible/`
- Closed-project archive: `<workspace>/ansible_archive/`

Never place Ansible project files elsewhere in the workspace merely for convenience.

## When to Use

Use this skill for:

- Ansible playbooks, roles, inventories, variable files, templates, plugins, and configuration
- Ansible collections developed or installed for workspace work
- Python dependencies needed by Ansible modules, filters, inventory plugins, or helper scripts
- Connectivity and privilege-escalation checks against managed systems
- Pull requests or completed tasks involving files under `ansible/`
- Cleanup or archival of completed Ansible work

Do not use it to move unrelated workspace content into `ansible/`, or to archive active/shared automation without explicit user agreement. A repository contribution that merely packages or documents this skill is not itself Ansible automation: keep every non-Ansible-native Git checkout under `<workspace>/git/<repository-name>/` and archive it under `<workspace>/git_archive/<repository-name>/` according to `hermes-workspace-git`. Classify by the repository's primary purpose, not by the current task or one Ansible-related file.

## 1. Inspect Before Working

1. Read workspace instructions such as `<workspace>/AGENTS.md` and inspect the existing `ansible/` layout, configuration, inventories, dependency files, and local conventions.
2. Load `hermes-workspace-manager` when available and classify the task as Ansible-native work.
3. Resolve `<workspace>/ansible/` or the smallest unambiguous existing project/subtree beneath it as the topic scope. Shared flat layouts may require the Ansible root; do not invent a project directory or create `<workspace>/<topic-name>` for the same work.
4. Check version-control status before editing. Treat uncommitted or untracked files as potentially owned by another team member.
5. Identify the smallest task-specific set of files. Reuse existing directories and naming conventions rather than creating parallel structures.
6. Keep secrets out of playbooks, inventories, logs, requirement files, and commits. Use the project's established vault or secret-management mechanism.

This step is complete only when the applicable project instructions and pre-existing changes are known and every planned file has a destination under `ansible/`.

## 2. Keep All Ansible Work Under `ansible/`

Place artifacts according to the existing layout, normally:

```text
ansible/
├── ansible.cfg
├── collections/
│   └── requirements.yml
├── filter_plugins/
├── inventory/
├── library/
├── playbooks/
├── requirements.txt
├── roles/
├── templates/
└── tests/
```

The current repository layout takes precedence over this example. Put temporary inventories, rendered test output, helper scripts, downloaded roles or collections, retry files, caches, and other task-specific artifacts inside an appropriate ignored location under `ansible/`; remove disposable artifacts before completion.

Do not write task artifacts to the workspace root, `/tmp`, or an unrelated repository directory when an `ansible/`-local location can serve the same purpose. If a tool inherently uses a system temporary directory, ensure it leaves no task-owned residue there.

## 3. Record Dependencies Reproducibly

### Python modules

If Ansible work requires installing a Python package, add a direct, reproducible dependency entry to:

```text
<workspace>/ansible/requirements.txt
```

Create the file if it does not exist. Preserve the file's existing version and hash conventions. Do not add packages that were merely inspected or are already supplied by the documented base environment unless the automation truly depends on them.

Install from the requirement file rather than leaving the environment as the only record:

```bash
python3 -m pip install -r ansible/requirements.txt
```

Prefer a project virtual environment located under `ansible/` when one is needed, and keep it ignored by version control.

### Ansible collections

If work requires an Ansible collection, record it in:

```text
<workspace>/ansible/collections/requirements.yml
```

Preserve valid YAML and existing source/version conventions. Install from that manifest:

```bash
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

If a role dependency is needed, use the repository's established role requirements file rather than silently treating it as a collection. Do not hand-edit downloaded collection contents in place; modify source maintained under `ansible/` or pin the required upstream version.

Dependency work is complete only when a clean environment can discover every newly required direct dependency from the committed requirement files.

## 4. Connect to Managed Systems Safely

### Default identity and privilege behavior

Use the agent's authorized private SSH key and connect as `root` by default. If the user specifies another remote account, use that account exactly as directed:

- Non-root account with sudo: set the requested remote user and use Ansible privilege escalation only where required (`become: true`).
- Non-root account without sudo: do not assume or attempt root privileges; constrain tasks to that account's permissions.
- Root account: do not add unnecessary `become` settings.

Treat authentication and privilege escalation as separate concerns. Never expose, copy, print, commit, or transmit the private key. Do not disable SSH host-key checking as a shortcut. Ask before accepting a changed host key.

### Verify access

Use a non-interactive connectivity check before running changes, followed by an Ansible ping or check-mode operation appropriate to the inventory. Avoid commands that may prompt indefinitely.

If access succeeds, verify the actual remote user and required privilege path before making changes. If access fails, distinguish DNS/routing, host-key, authentication, account, and sudo failures from the command output rather than calling every failure a key problem.

### If the target does not authorize the agent's key

Give the user the matching **public** key and state which remote account needs access. Use an existing `.pub` file that corresponds to the selected private key, or derive only the public key with `ssh-keygen -y -f <private-key-path>`. Never display the private key.

Provide installation help if needed. For root access, the user can run on the target console or through an already authorized administrator:

```bash
install -d -m 700 /root/.ssh
PUBLIC_KEY='PASTE_THE_PUBLIC_KEY_HERE'
grep -qxF "$PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

For a named non-root account, install the key in that user's home and set ownership:

```bash
TARGET_USER='CHANGE_ME'
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.ssh"
PUBLIC_KEY='PASTE_THE_PUBLIC_KEY_HERE'
touch "$TARGET_HOME/.ssh/authorized_keys"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.ssh/authorized_keys"
chmod 600 "$TARGET_HOME/.ssh/authorized_keys"
grep -qxF "$PUBLIC_KEY" "$TARGET_HOME/.ssh/authorized_keys" || printf '%s\n' "$PUBLIC_KEY" >> "$TARGET_HOME/.ssh/authorized_keys"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.ssh/authorized_keys"
```

Tell the user to verify the account name, home directory, SSH server configuration, and any centralized access-management policy before changing `authorized_keys`. After they grant access, retry the non-interactive connectivity check. Do not claim target verification until it succeeds.

## 5. Validate the Automation

Run checks from the workspace using the repository's configuration and documented commands. At minimum, where applicable:

1. Parse YAML and requirement manifests.
2. Run `ansible-playbook --syntax-check` against changed playbooks with the intended inventory.
3. Run linting if the project has `ansible-lint` or another established checker.
4. Exercise check mode when modules and target behavior support it.
5. Run the narrow live path only with authorization, then verify the resulting system state.
6. Re-run idempotent automation and confirm that the second run reports no unexpected changes.

State explicitly when check mode, idempotency, or live-system verification is unavailable. Validation is complete only when the changed files and the intended target behavior have been checked at a level appropriate to their impact.

## 6. Clean Up and Archive Completed Work

### Before completion

Remove disposable files created during the task from within `ansible/`, including retry files, caches, temporary inventories, rendered scratch output, and test-only downloads. Do not remove pre-existing or user-owned files. Keep files required to reproduce, operate, review, or roll back the automation.

### When a pull request is created

Do not archive immediately. Ask the user whether cleanup and archival should happen now, and offer a concrete list of what would be cleaned up or moved. For example:

- Disposable files to delete: exact paths and why they are no longer needed
- Completed project files to archive: exact source and proposed archive destination
- Files to retain: shared requirements, configuration, inventories, or reusable roles still needed by active work

A useful prompt is:

> The pull request is created. Should I clean up the completed Ansible work now? I would remove `<disposable paths>` and move `<completed paths>` to `<workspace>/ansible_archive/<relative paths>`. I would retain `<shared or active paths>`.

Do not perform the archival until the user agrees.

### Archive procedure after approval

1. Recheck version-control status and confirm the offered source paths have not changed ownership or purpose.
2. Create `<workspace>/ansible_archive/` and preserve each archived file's path relative to `ansible/`.
3. Move only the approved files; do not copy them and leave duplicate active files behind.
4. If the destination name already exists, append a local timestamp in `YYYYMMDD_HHMM` form to the filename. Never overwrite an existing archive.

Example:

```text
Source:      ansible/playbooks/upgrade_os.yml
Destination: ansible_archive/playbooks/upgrade_os.yml
Conflict:    ansible_archive/playbooks/upgrade_os.yml.20260720_1227
```

Generate the suffix at move time with `date +%Y%m%d_%H%M`; do not guess it. Create destination parent directories before moving. Requirement manifests and shared configuration should move only when they are exclusively part of the approved closed project; otherwise remove only obsolete project-specific entries after checking that active automation does not use them.

5. Inspect `ansible/` and `ansible_archive/` after the move, and show the resulting version-control status or file list. Confirm every approved path was moved and no unapproved file was changed.

Cleanup is complete only when disposable task-owned residue is gone, approved closed-project files are safely archived without overwrites, and remaining active automation is intact.

## Common Pitfalls

1. **Working outside `ansible/`.** Move active Ansible artifacts into the established tree before continuing and remove accidental duplicates.
2. **Installing dependencies without recording them.** Add Python packages and collections to their requirement manifests, then install from those files.
3. **Archiving automatically at PR creation.** Offer exact cleanup actions and wait for user agreement.
4. **Overwriting an archive conflict.** Append the real `YYYYMMDD_HHMM` timestamp to the destination filename.
5. **Archiving shared files wholesale.** Retain shared configuration and manifests unless the user approves moving them and no active automation depends on them.
6. **Assuming sudo.** Follow the user's selected account and privilege model; verify it before execution.
7. **Treating every SSH failure as missing authorization.** Diagnose network, host-key, account, and sudo errors first.
8. **Leaking credentials.** Public keys may be shared for authorization; private keys and secrets must never be exposed.
9. **Claiming success after syntax check alone.** Verify target behavior and idempotency when access and risk permit.

## Verification Checklist

- [ ] Workspace instructions and existing Ansible conventions were inspected
- [ ] The Ansible root or established project/subtree is the single resolved topic scope; no duplicate generic topic folder exists
- [ ] All active Ansible task files are under `<workspace>/ansible/`
- [ ] No unrelated or pre-existing work was overwritten or removed
- [ ] New Python dependencies are in `ansible/requirements.txt`
- [ ] New collections are in `ansible/collections/requirements.yml`
- [ ] SSH account and privilege behavior match the user's direction
- [ ] Private keys and secrets were not disclosed
- [ ] Syntax, lint, check mode, live behavior, and idempotency were verified where applicable
- [ ] Disposable task-owned files under `ansible/` were removed
- [ ] At PR creation, exact cleanup candidates were offered and user consent was obtained before archival
- [ ] Approved files were moved to `ansible_archive/` with relative paths preserved
- [ ] Archive conflicts received a real timestamp suffix and no archive was overwritten
- [ ] Final active and archived contents were inspected and reported
