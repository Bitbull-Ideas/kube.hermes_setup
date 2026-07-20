---
name: hermes-workspace-git
description: Use when cloning, creating, modifying, reviewing, or cleaning up Git repositories in a Hermes workspace. Keep non-Ansible repositories under the workspace git/ directory, preserve repository boundaries and local instructions, and use consent-based cleanup and archival under git_archive/ after pull-request work is complete.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [git, workspace, repositories, cleanup, archive, collaboration]
    related_skills: [github-pr-workflow, github-repo-management, hermes-workspace-ansible]
---

# Hermes Workspace Git

## Overview

Act as a considerate team member whenever work requires a Git clone, repository, or worktree in a Hermes workspace. Keep general Git repositories together, protect unrelated work, and make active versus closed projects obvious.

Use `<workspace>` for the active workspace supplied by Hermes. The standard paths are:

- Active non-Ansible repositories: `<workspace>/git/`
- Archived non-Ansible repositories: `<workspace>/git_archive/`
- Active Ansible automation: `<workspace>/ansible/`
- Archived Ansible automation: `<workspace>/ansible_archive/`

Each active repository normally lives at:

```text
<workspace>/git/<repository-name>/
```

Each archived repository normally lives at:

```text
<workspace>/git_archive/<repository-name>/
```

Never clone a general software, documentation, infrastructure, or bootstrap repository into `ansible/` merely because the task mentions Ansible or changes an Ansible-related file. Classify by the repository's primary purpose, not by one file or task.

## When to Use

Use this skill when:

- Cloning an existing Git repository.
- Initializing a new Git repository.
- Creating branches, commits, tags, forks, or pull requests.
- Reviewing or modifying a repository already present in the workspace.
- Retaining a clean working tree for pull-request revisions.
- Cleaning up or archiving completed repository work.
- Correcting a repository that was placed in the wrong workspace directory.

Do not use `git/` as a general scratch directory. Non-repository outputs belong in a task-appropriate workspace directory. Do not move a repository that the user explicitly located elsewhere unless they ask for workspace normalization or the placement violates these established workspace rules.

## 1. Classify Before Cloning or Moving

Determine the repository's primary purpose before choosing a path.

### Ansible-native repositories

Use `<workspace>/ansible/` only when the repository itself is primarily one of these:

- Ansible playbook repository
- Ansible role repository
- Ansible collection repository
- Ansible inventory or automation repository

Follow `hermes-workspace-ansible` for those repositories and archive them under `ansible_archive/`.

### All other Git repositories

Use `<workspace>/git/` for every other repository, including:

- Application and library source repositories
- Kubernetes, Helm, Terraform, platform, or installer repositories
- Documentation repositories
- Bootstrap and configuration repositories
- Repositories that merely contain Ansible examples, roles, playbooks, or documentation as one component
- Repositories used to publish or package an Ansible skill but whose primary purpose is not Ansible automation

Example classification:

```text
kube.hermes_setup
  Primary purpose: Kubernetes/K3s installer and Hermes bootstrap repository
  Active path:     <workspace>/git/kube.hermes_setup
  Archive path:    <workspace>/git_archive/kube.hermes_setup
```

Do not infer classification from the remote hosting service, repository name alone, or the current task. Inspect the README, top-level tree, repository description, and maintainer instructions first.

Classification is complete only when the repository's primary purpose and exact active path are explicit.

## 2. Prepare the Workspace Safely

Before cloning or creating a repository:

1. Read `<workspace>/AGENTS.md` and any other workspace-level instructions.
2. Inspect `<workspace>/git/` for an existing clone with the same repository identity.
3. Inspect `<workspace>/git_archive/` for a prior closed copy that may contain useful history or indicate a naming conflict.
4. Create `<workspace>/git/` if it does not exist.
5. Use one directory per repository; do not mix unrelated repositories in one working tree.

For a clone:

```bash
mkdir -p <workspace>/git
git clone https://github.com/OWNER/REPOSITORY.git \
  <workspace>/git/REPOSITORY
```

Before cloning, check whether the destination exists. Never overwrite or delete an existing directory to make room. If the same remote is already present and clean, inspect whether it can be reused. If it is active, dirty, or owned by another task, preserve it and choose a clearly distinct worktree or ask when ownership cannot be determined.

Do not place access tokens in clone URLs. Use an SSH identity, credential helper, askpass helper, or a non-logging API authentication mechanism.

Preparation is complete only when the selected path is collision-free and no existing work was overwritten.

## 3. Inspect the Repository Before Changing It

After entering `<workspace>/git/<repository-name>/`:

1. Read repository guidance in this order where present:
   - `AGENTS.md`
   - `AGENT.md`
   - `CLAUDE.md`
   - `.cursorrules`
   - `CONTRIBUTING.md`
   - `README.md`
   - security and release documentation relevant to the task
2. Inspect `git status --short --branch`, remotes, current branch, default branch, and recent history.
3. Treat every pre-existing modified, staged, or untracked file as potentially user-owned.
4. Identify repository-specific build, test, lint, formatting, signing, and commit conventions.
5. Confirm the destination remote and base branch before publishing.

Do not use destructive cleanup commands such as `git reset --hard`, `git clean -fd`, branch force deletion, or forced push to erase unexpected state. Stop and report ambiguous ownership instead.

Inspection is complete only when repository instructions, pre-existing state, remotes, and the intended base branch are known.

## 4. Work Within the Repository Boundary

Keep repository-specific source, tests, generated fixtures, dependency manifests, and task artifacts inside the repository at `<workspace>/git/<repository-name>/`, following its own conventions.

Rules:

- Use a focused feature branch unless the maintainer explicitly requires another workflow.
- Make the smallest correct change and preserve unrelated files.
- Put dependencies in the repository's established manifest and lock files.
- Keep generated or temporary files ignored unless the repository intentionally tracks them.
- Never commit credentials, private infrastructure details, local environment files, generated backups, or authentication state.
- Use sanitized placeholders in public repositories.
- Verify changed behavior with the repository's documented checks.

The workspace `git/` directory is a container for repositories, not a shared dependency or artifact directory. Do not create files such as `git/requirements.txt`, `git/package.json`, or `git/.env` for multiple repositories.

When a task spans several repositories, keep each as a sibling:

```text
<workspace>/git/service-api/
<workspace>/git/service-ui/
<workspace>/git/deployment-config/
```

Track and report changes per repository. Never assume one repository's instructions apply to another.

## 5. Verify Before Publishing

Before committing or pushing:

1. Run targeted tests for the changed behavior.
2. Run repository-required formatters, linters, static checks, and broader tests appropriate to impact.
3. Run `git diff --check`.
4. Review the complete diff, including staged and untracked files intended for commit.
5. Scan for secrets and private values using repository-approved tooling or a focused pattern scan.
6. Confirm the commit contains only intended paths.
7. Verify the working tree is clean after commit.

Before creating a pull request:

1. Push only the intended feature branch or fork branch.
2. Confirm the remote branch resolves to the expected commit SHA.
3. Create the PR against the intended base repository and branch.
4. Verify the returned PR URL, state, head, base, commit count, and changed-file count.
5. Check available CI/check-run status and report when no automated checks exist.

Do not claim success merely because `git push` exited successfully. A published task is complete only when the remote branch and PR, when requested, are verified.

## 6. Clean Up During Work

Remove only disposable artifacts created by the current task, such as:

- Temporary patch or diff files
- Build caches not intentionally retained
- Generated test output
- Downloaded archives
- Editor backup files
- One-time credential helpers
- Temporary rendered output

Use the repository's clean command when it is safe and documented, or remove exact known task-owned paths. Do not remove pre-existing untracked files or broad file classes without proving ownership.

A clean repository means `git status --porcelain` is empty. It does not mean the repository itself is disposable.

## 7. Pull-Request Cleanup Decision

When a pull request is created, do not immediately archive the working repository. An open PR may need review fixes. Ask the user what to do and offer a concrete accounting:

- Disposable files to delete now, with exact paths
- Active repository to retain until merge, with exact path
- Completed repositories eligible for immediate archival
- Any sibling repositories or shared workspace paths that will remain untouched

Offer these choices when applicable:

1. Keep the clean repository under `<workspace>/git/` until the PR is merged; this is the recommended default for an open PR.
2. Archive the repository now under `<workspace>/git_archive/`.
3. Leave cleanup for the user to handle later.

A useful prompt is:

> The pull request is created. There are `<disposable paths or none>` to delete. The clean active repository is `<workspace>/git/<name>`; I recommend retaining it until merge so review changes can be applied. If archived now, it would move to `<workspace>/git_archive/<name>`. Should I retain it, archive it now, or leave cleanup for later?

Do not archive or delete until the user agrees. If the user chooses to retain it, leave the working tree clean and re-offer cleanup after the merge is observed or reported.

## 8. Archive a Completed Repository

After the user approves archival—or after a previously retained PR is merged and the user has already authorized post-merge archival—use this procedure:

1. Recheck PR/branch state and `git status --porcelain`.
2. Preserve uncommitted work; do not archive a dirty repository without explicitly reporting it and obtaining approval.
3. Fetch/prune if authentication and network access are available.
4. Switch to the default branch and fast-forward it to the verified remote default branch when safe.
5. Delete obsolete feature branches only when merged and approved. Never force-delete an unmerged branch merely to make cleanup easier.
6. Create `<workspace>/git_archive/`.
7. Move the whole repository directory, including `.git`, from `git/` to `git_archive/`.
8. Verify the source path is absent, the destination is a valid Git working tree, its status is clean, and its HEAD is the expected commit.

Example:

```text
Source:      <workspace>/git/kube.hermes_setup
Destination: <workspace>/git_archive/kube.hermes_setup
```

If the destination already exists, never overwrite or merge directory trees. Append the actual local timestamp in `YYYYMMDD_HHMM` format to the repository directory name:

```text
<workspace>/git_archive/kube.hermes_setup.20260720_1227
```

Generate it at move time:

```bash
date +%Y%m%d_%H%M
```

If a same-minute conflict also exists, generate a new unique suffix rather than overwriting. Preserve the repository's remote configuration and history unless the user explicitly requests a source-only archive.

Archival is complete only when the repository exists solely at the approved archive destination and its Git state is verified.

## 9. Correct a Misplaced Repository

When a general repository is found under `ansible/` or `ansible_archive/`:

1. Confirm it is not Ansible-native using its README, top-level tree, and stated purpose.
2. Check its working tree and current PR state.
3. Select the corresponding correct destination:
   - Active work: `<workspace>/git/<repository-name>`
   - Closed/merged work: `<workspace>/git_archive/<repository-name>`
4. Apply the same no-overwrite timestamp rule on conflicts.
5. Move the whole repository, including `.git`.
6. Verify source absence, destination existence, clean status, remotes, and HEAD.

Do not leave a duplicate in the old location. Report the correction explicitly.

## Common Pitfalls

1. **Classifying by task instead of repository purpose.** Editing an Ansible example does not make a Kubernetes installer an Ansible repository.
2. **Cloning at workspace root.** General repositories belong under `git/`.
3. **Putting all Git repositories under `ansible/`.** Reserve `ansible/` for Ansible-native repositories and automation.
4. **Treating a clean clone as disposable.** Retain it while an open PR may need revisions.
5. **Archiving immediately after PR creation.** Offer exact cleanup choices and wait for agreement.
6. **Overwriting an archive.** Add a real timestamp suffix to the repository directory.
7. **Mixing repositories.** Use one directory per repository and preserve each `.git` boundary.
8. **Deleting unknown untracked files.** Establish ownership before cleanup.
9. **Embedding tokens in remote URLs.** Keep credentials out of repository configuration and diagnostics.
10. **Claiming publication without verification.** Verify the remote branch and PR through Git/API evidence.
11. **Leaving stale feature branches after a merged PR.** Remove them only after confirming merge and authorization.
12. **Archiving a dirty tree silently.** Report and preserve uncommitted work.

## Verification Checklist

- [ ] Repository primary purpose was inspected and classified
- [ ] Non-Ansible repository is under `<workspace>/git/<name>` while active
- [ ] Ansible-native repositories remain governed by `hermes-workspace-ansible`
- [ ] Workspace and repository instructions were read
- [ ] Existing repository state and unrelated work were preserved
- [ ] Repository-specific dependencies and artifacts stayed within its boundary
- [ ] Tests, lint, diff checks, and secret scans were run as applicable
- [ ] Feature branch, remote commit, and PR were verified when published
- [ ] Disposable task-owned files were removed
- [ ] PR-time cleanup options named exact paths and required user consent
- [ ] Open-PR working tree was retained when requested
- [ ] Completed repository was moved to `<workspace>/git_archive/<name>` when approved
- [ ] Archive conflicts received a real `YYYYMMDD_HHMM` suffix
- [ ] Source path is absent after archival
- [ ] Archived repository remains a valid, clean Git working tree at the expected HEAD
- [ ] No credentials or private data were exposed
