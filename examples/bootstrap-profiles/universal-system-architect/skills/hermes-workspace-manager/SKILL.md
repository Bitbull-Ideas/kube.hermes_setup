---
name: hermes-workspace-manager
description: "Use when task-related files or persistent work are organized under the active workspace: resolve one topic folder, keep artifacts contained, preserve continuity, and explicitly archive finished work."
version: 1.2.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [workspace, session-management, topic-folders, artifacts, archiving, follow-up]
    related_skills: [hermes-workspace-git, hermes-workspace-ansible]
---

# Hermes Workspace Manager

## Scope

Organize task-related files and persistent work beneath the active workspace. This skill provides the generic location and lifecycle layer; user direction, project instructions, and task-specific skills govern the contents and may define a specialized topic location.

Resolve a topic folder before creating, downloading, copying, generating, or modifying task-related files. Every user-visible, task-related artifact under the agent's control must stay inside that folder. Use subdirectories such as `downloads/`, `tmp/`, `logs/`, or `output/` when useful. Do not leave task artifacts directly in the workspace root or outside the active workspace.

An ephemeral conversation that creates or changes no task-related files does not require a topic folder.

## Placement Precedence

Classify the task before choosing a folder:

1. **Git repository work:** follow `hermes-workspace-git`. Use `<workspace>/git/<repository-name>` as the topic folder and `<workspace>/git_archive/<repository-name>` for approved archival.
2. **Ansible-native work:** follow `hermes-workspace-ansible`. Resolve either `<workspace>/ansible` itself or one established project/subtree beneath it as the topic scope, according to the existing layout. Archive only the approved completed paths beneath `<workspace>/ansible_archive`, preserving relative paths.
3. **All other persistent work:** use a direct child topic folder at `<workspace>/<topic-name>` and archive it beneath `<workspace>/_archive` when requested.

These are specialized routing rules, not competing workspace models. Once a specialized skill selects a Git repository directory or an Ansible workspace/project scope, that location is resolved for this skill. Never create a second generic topic folder for the same work. An Ansible topic scope may contain shared active files; resolving it does not make the whole scope eligible for archival.

## Resolve the Topic

1. Use the latest `[Workspace::v1: ...]` path as `<workspace>`.
2. Inspect its direct child folders and the applicable specialized container (`git/`, `git_archive/`, `ansible/`, or `ansible_archive/`) when relevant.
3. If one folder clearly matches the task, use it and inspect relevant instructions, notes, plans, TODOs, repository state, and artifacts before continuing.
4. If the topic is new and its name is unambiguous, create it at the location selected by the placement rules using a short, stable, lowercase hyphenated name.
5. If several folders could match, or the topic, classification, or name is unclear, ask before creating or moving anything.

Do not create duplicate topic folders. Keep follow-up work, scheduled results, and related artifacts in the same topic folder.

Files created automatically outside the topic folder by tools, package managers, or the operating system must be moved into it when practical. Otherwise, identify them as transient, system-managed, or unsafe to relocate; do not move them blindly.

Completion criterion: before task-related file operations begin, one unambiguous topic folder has been resolved and relevant continuity artifacts have been inspected.

## Finish or Archive

When the requested work is solved, ask whether follow-up is needed.

- **Follow-up:** leave the topic at its active resolved location.
- **Archive requested:** use the archive location selected by the placement rules.
- Create the selected archive container when necessary.
- Never overwrite an existing archive. If the destination exists, append a timestamp using the format required by the specialized skill; for generic topics use `<topic-name>.YYYYMMDDhhmm`. If that also exists, generate another unique timestamp or ask.
- Archive only inside the active workspace.
- After moving, verify that every approved moved source path is absent and the destination contains the expected files. For generic and Git topics this is normally the whole topic directory; for Ansible it may be only selected completed files.

Do not archive merely because the current conversation turn ended. Specialized skills may require additional checks or explicit consent before archival; follow the stricter rule.

## Safety Invariants

- The latest workspace marker overrides remembered or hardcoded paths.
- Inspect before creating, overwriting, moving, or archiving.
- Apply specialized Git or Ansible placement before the generic direct-child rule.
- Preserve useful artifacts and update them in place when appropriate.
- Do not move, rename, delete, or archive when ownership or destination is ambiguous.
- Do not silently discard files.

## Verification

Before substantive task work:

- [ ] The active workspace came from the latest workspace marker.
- [ ] The task was classified as Git, Ansible-native, or generic work.
- [ ] Existing direct child folders and any applicable specialized container were inspected.
- [ ] The selected or created topic folder is unambiguous.
- [ ] Relevant continuity artifacts and project instructions were inspected.
- [ ] Every task-related file created, downloaded, copied, or generated is inside the topic folder.
- [ ] No task artifacts were left directly in the workspace root.
- [ ] Any unavoidable external or system-managed files were identified.

After archiving:

- [ ] The destination uses `_archive`, `git_archive`, or `ansible_archive` according to task classification.
- [ ] Any collision was handled without overwriting.
- [ ] Specialized consent and state checks were satisfied.
- [ ] Every approved moved source path no longer exists; shared Ansible workspace content remains intact.
- [ ] The destination contains the expected files.
