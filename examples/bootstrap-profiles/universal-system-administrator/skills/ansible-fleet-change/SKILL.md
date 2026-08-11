---
name: ansible-fleet-change
description: "Use when a change must be applied to multiple hosts — write an Ansible playbook, run it with explicit authorization, log /CHANGES.md entries per host, and verify each target."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [ansible, fleet, multi-host, automation, playbook]
    related_skills: [linux-triage, linux-change-safety]
---

# Ansible Fleet Change

## Trigger

A change is authorized for multiple hosts. Prefer Ansible over per-host SSH.

## Prerequisites

- Ansible is installed on the control node and the inventory exists.
- Target systems are properly defined and accessible.
- Access is configured (SSH keys, become, etc.).
- The operator has confirmed the target group or pattern.

## Workflow

1. **Identify the target hosts** from inventory:
   ```bash
   ansible <group> --list-hosts
   ```
   Confirm with the operator before proceeding.

2. **Start with a canary host** — one non-critical system:
   ```bash
   ansible-playbook playbooks/<change>.yml --limit <canary-host> --check
   ```
   Review the check output. If clean, run without `--check`:
   ```bash
   ansible-playbook playbooks/<change>.yml --limit <canary-host>
   ```
   Verify the result on the canary:
   ```bash
   ansible <canary-host> -m command -a 'systemctl is-active <service>'
   ansible <canary-host> -m shell -a 'tail -3 /CHANGES.md'
   ```

3. **After canary success**, roll to the fleet:
   ```bash
   ansible-playbook playbooks/<change>.yml --limit <group>
   ```

4. **Write /CHANGES.md as a playbook task**, not from memory afterward. Add to your playbook:
   ```yaml
   - name: Log change in /CHANGES.md
     ansible.builtin.lineinfile:
       path: /CHANGES.md
       line: "{{ ansible_date_time.date }};{{ ansible_date_time.hour }}{{ ansible_date_time.minute }};BOB_HERMES_AGENT;{{ change_reason }};{{ downtime }};{{ error_description }};{{ solution_description }}"
       create: yes
       mode: '0600'
       owner: root
       group: root
     vars:
       change_reason: "Zabbix Alert"
       downtime: "00:02"
       error_description: "Service jellyfin failed to start"
       solution_description: "fixed syntax in /etc/jellyfin/system.xml"
   ```
   Or for a simple header+entry:
   ```yaml
   - name: Ensure /CHANGES.md exists with header
     ansible.builtin.copy:
       content: "DATE;TIME;WHO;WHY;DOWN_TIME;ERROR_DESC;SOLUTION_DESC\n"
       dest: /CHANGES.md
       force: false
       mode: '0600'
       owner: root
       group: root
   - name: Append change entry
     ansible.builtin.lineinfile:
       path: /CHANGES.md
       line: "..."
   ```

5. **Verify every target** — not just the first few:
   ```bash
   ansible <group> -m command -a 'systemctl is-active <service>'
   ansible <group> -m shell -a 'tail -1 /CHANGES.md'
   ```

## Safety rules

- `--check` does NOT protect `command`/`shell`/`raw`/`script` modules. Only use these during investigation if the command is provably read-only. For change playbooks, use native modules (`copy`, `template`, `lineinfile`, `systemd`, `package`) that respect `--check`.
- Always canary first. Full group roll only after the canary is verified.
- The playbook and inventory are version-controlled. Commit the playbook with a message after use:
  ```bash
  git add playbooks/<change>.yml
  git commit -m "feat: add playbook for <change-description>"
  ```
- Ansible writes to control-node files, not target files. A change to the control node (playbook, inventory) is not logged in the target's `/CHANGES.md` — it's logged in the control node's git history.

## Pitfalls

- `ansible <group> -m shell` runs on the control node if the group is empty. Always `--list-hosts` first.
- Variable precedence: playbook `vars` < group_vars < host_vars < extra vars. If a value is unexpectedly overridden, check all precedence levels.
- Permissions inside a loop: `become` inside `with_items` requires `become: yes` on the loop task, not just on the play.
- The `lineinfile` `create: yes` option creates the file at root-owned, but with the default umask if `mode` is not set.

## Verification

- [ ] Target list confirmed with operator
- [ ] Canary host check passed
- [ ] Fleet run completed without failures
- [ ] /CHANGES.md entries exist on each target
- [ ] Service health confirmed on all targets
- [ ] Playbook committed to version control
- [ ] Rollback playbook exists or rollback steps are documented
