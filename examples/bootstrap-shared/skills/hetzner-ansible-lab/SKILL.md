---
name: hetzner-ansible-lab
description: "Provision temporary Hetzner Cloud VMs for Ansible role QA, bootstrap OS prerequisites such as Rocky 8 Python 3.9, run verified work, clean up cloud resources, and report sanitized evidence."
version: 1.0.1
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [hetzner, hcloud, ansible, lab, qa, cloud, devops]
    related_skills: []
    source: https://github.com/Bitbull-Ideas/hermes.skills/tree/e7056a42855bbe2b6588786cb07c2daa3f4384f8/skills/devops/hetzner-ansible-lab
    source_commit: e7056a42855bbe2b6588786cb07c2daa3f4384f8
    modified: true
---

# Hetzner Ansible Lab

Use this skill when a user wants temporary Hetzner Cloud servers for Ansible-driven QA, role testing, install validation, upgrade testing, or multi-OS matrix verification.

The lifecycle is:

1. decide the OS matrix and server shape,
2. communicate the planned Hetzner setup and ask for explicit go,
3. create labelled temporary VMs via API,
4. prepare OS prerequisites such as Rocky 8 Python 3.9,
5. run the requested Ansible work and independent verification,
6. delete all temporary cloud resources,
7. report precise, sanitized results.

Never publish private hostnames, real temporary IPs, cloud tokens, SSH keys, usernames, credentials, or private inventory details in public docs, PR bodies, changelogs, or final summaries unless the user explicitly asks for that private operational detail.

## When to use

Use this skill when:

- the user asks to test an Ansible role on real cloud VMs,
- local lab capacity is not appropriate or not available,
- the test needs fresh public-cloud OS images,
- the role behavior depends on package managers, reboot behavior, cloud networking, distro Python versions, or real service lifecycle,
- the user asks for temporary Hetzner VMs and cleanup after testing.

Do not use this skill for:

- production provisioning,
- long-lived server creation,
- tests that can be answered safely with local syntax checks only,
- persisting inventories, cloud state files, logs, or provider metadata in a public repository.

## Required inputs and confirmation

Before creating anything, decide and communicate:

- cloud provider: Hetzner Cloud,
- location, for example `fsn1`,
- server type, for example `cpx22` for moderate Ansible package/update testing,
- OS image list, for example:
  - Ubuntu 24.04,
  - Ubuntu 26.04 if available,
  - Rocky Linux 8,
  - Rocky Linux 9,
  - Rocky Linux 10 if available,
- expected runtime/cost rough order,
- labels used for cleanup,
- whether Windows is needed. Hetzner Cloud is Linux-first for this workflow; Windows needs a separate provider/image strategy unless already prepared.

Ask for explicit go before provisioning. Creating cloud servers and public IPv4 addresses costs money.

Example confirmation message:

```text
I will create 5 temporary Hetzner Cloud VMs in <location> using <server_type>:
Ubuntu 24.04, Ubuntu 26.04, Rocky 8, Rocky 9, Rocky 10.
They will be labelled purpose=<purpose>, owner=<agent-or-user>, run_id=<run_id> and deleted after testing.
I will keep inventories/state outside the repository and will not include IPs, hostnames, tokens, or credentials in public output. Go?
```

## Prerequisites

- `HCLOUD_TOKEN` or an equivalent Hetzner Cloud API token must be available in the environment. Verify presence without printing the value:

  ```bash
  if [ -n "${HCLOUD_TOKEN:-}" ]; then echo "HCLOUD_TOKEN present length=${#HCLOUD_TOKEN}"; else echo "HCLOUD_TOKEN missing"; fi
  ```

- Discover the local Ansible binaries instead of assuming a path:

  ```bash
  ANS=${ANSIBLE_BIN:-$(command -v ansible)}
  PB=${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook)}
  "$ANS" --version
  "$PB" --version
  ```

  If your environment has a pinned Ansible runtime, use that explicit path for reproducibility and record it in the report.

- Discover or select an SSH key via Hetzner API. Do not hardcode SSH key IDs in reusable docs.
- Create a project-specific lab directory under `<workspace>/<project-lab>/`.
- Keep generated files out of the tested repository:
  - `state.json`,
  - `inventory.ini`,
  - `ssh_config`,
  - `logs/`,
  - ad-hoc playbooks.

## Provider lifecycle pattern

Use the Hetzner API with labels for every resource. At minimum:

```text
purpose=<short-purpose>
owner=<agent-or-user>
run_id=<timestamp-or-uuid>
repo=<repo-or-role-name>
```

Before creating new servers, query for existing labelled resources with the same purpose and refuse to continue if leftovers exist unless the user explicitly asks to reuse or delete them.

Use a state file in the lab directory, not the repo:

```json
{
  "run_id": "<run-id>",
  "created_at_utc": "<timestamp>",
  "labels": {
    "purpose": "<purpose>",
    "owner": "<agent-or-user>",
    "repo": "<repo>",
    "run_id": "<run-id>"
  },
  "servers": [
    {
      "id": 123,
      "name": "<sanitized-name>",
      "image": "ubuntu-24.04",
      "short": "ubuntu24",
      "status": "running",
      "ip": "<temporary-ip>"
    }
  ]
}
```

The state file may contain temporary IPs and provider IDs. Do not commit it. Do not paste it into public PR bodies.

## SSH host-key verification and inventory

Create a run-specific `known_hosts` file and a narrow SSH config inside the lab directory. Never disable host-key checking for public-cloud lab hosts.

For every newly provisioned VM:

1. Collect the presented ED25519 host key into a temporary candidate file with `ssh-keyscan`.
2. Display its fingerprint with `ssh-keygen -lf`.
3. Use the Hetzner Cloud Console as an independent trusted channel and run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the VM.
4. Add the candidate key to the run-specific `known_hosts` file only when both fingerprints match exactly. Stop and delete/recreate or investigate the VM on any mismatch.

Example after the provider console fingerprint has been obtained independently:

```bash
umask 077
test -e known_hosts || install -m 0600 /dev/null known_hosts
ssh-keyscan -T 10 -t ed25519 <temporary-ip> > host-key.candidate
ssh-keygen -lf host-key.candidate
# Compare the output with the fingerprint shown through the Hetzner Cloud Console.
cat host-key.candidate >> known_hosts
rm -f host-key.candidate
```

Do not treat `ssh-keyscan` by itself as verification; it only retrieves the key presented on the current network path.

Use the verified run-specific file in `ssh_config`:

```sshconfig
Host *
    StrictHostKeyChecking yes
    UserKnownHostsFile /absolute/path/to/lab/known_hosts
    LogLevel ERROR
    ConnectTimeout 10
    ServerAliveInterval 10
    ServerAliveCountMax 3
```

For INI inventory host variables, quote `ansible_ssh_common_args` because the value contains a space. Unquoted values fail inventory parsing with errors like `Expected key=value host variable assignment`.

Correct pattern:

```ini
[hetzner_lab]
ubuntu24 ansible_host=<temporary-ip> ansible_user=root ansible_ssh_common_args='-F /path/to/lab/ssh_config'
rocky8 ansible_host=<temporary-ip> ansible_user=root ansible_ssh_common_args='-F /path/to/lab/ssh_config' ansible_python_interpreter=/usr/bin/python3.9

[rocky8_bootstrap]
rocky8
```

Avoid naming both a host and a group identically, for example host `rocky8` and group `[rocky8]`, because Ansible warns about host/group name collisions. Prefer `[rocky8_bootstrap]` for the bootstrap group.

Generate inventory directly from `state.json` so OS names map to the correct IPs. Do not manually reuse old IPs from previous runs.

## Rocky 8 / Enterprise Linux 8 preparation

Fresh Rocky 8 images expose Python 3.6 as `/usr/bin/python3`. Modern Ansible controller modules need Python >= 3.7 on the target.

Before facts or normal modules on Rocky 8, use `raw`. The inventory's `ansible_ssh_common_args` must point at the verified SSH config:

```bash
ANS=${ANSIBLE_BIN:-$(command -v ansible)}
"$ANS" -i inventory.ini rocky8_bootstrap -m raw -a \
  'set -e; dnf -y module enable python39; dnf -y install python39; /usr/bin/python3.9 --version'
```

Then pin Rocky 8 in inventory:

```ini
ansible_python_interpreter=/usr/bin/python3.9
```

Do **not** try `python39-libselinux` unless the current target repositories prove it exists. In tested Rocky 8 repositories it was unavailable and caused a failed attempt. Install `python39` only unless the current task proves an additional package is required.

## Pre-work checks

After provisioning and bootstrap, run:

```bash
ANS=${ANSIBLE_BIN:-$(command -v ansible)}
PB=${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook)}

"$ANS" -i inventory.ini hetzner_lab -m raw -a 'python3 --version || true; /usr/bin/python3.9 --version || true'
"$ANS" -i inventory.ini hetzner_lab -m ping
"$ANS" -i inventory.ini hetzner_lab -m setup -a 'filter=ansible_distribution*,ansible_python*'
"$PB" -i inventory.ini <playbook>.yml --syntax-check
```

Do not claim OS coverage until `setup` confirms each distro/version.

## Running the Ansible work

Create a test playbook in the lab directory that references the role under test through `ANSIBLE_ROLES_PATH=roles`. Symlink the role checkout into the lab harness:

```bash
mkdir -p roles
ln -sfn /path/to/role roles/<namespace>.<role_name>
```

For matrix testing, loop deliberately and keep logs per case:

```bash
for level in none security full; do
  for reboot in deny allow force; do
    case_name="level-${level}_reboot-${reboot}"
    ANSIBLE_ROLES_PATH=roles "$PB" -i inventory.ini test.yml \
      -e "os_update_level=${level}" \
      -e "os_update_reboot=${reboot}" \
      -e "os_update_remove_old_kernel=false" \
      -e "os_update_retry=1" \
      -e "os_update_retry_delay=5" \
      | tee "logs/${case_name}.log"
    rc=${PIPESTATUS[0]}
    echo "${case_name} rc=${rc}"
  done
 done
```

For long package updates or reboot-heavy runs, use tracked background execution with a completion notification and monitor progress. Do not interrupt package managers unless clearly stuck and safe to recover.

## Independent verification

After the role run, verify independently. For Linux update roles:

```yaml
- hosts: hetzner_lab
  gather_facts: true
  tasks:
    - command: uname -r
      register: kernel
      changed_when: false
    - command: uptime -s
      register: uptime_start
      changed_when: false
    - command: apt-get check
      register: apt_check
      changed_when: false
      failed_when: false
      when: ansible_os_family == 'Debian'
    - command: dnf -y check
      register: dnf_check
      changed_when: false
      failed_when: false
      when: ansible_os_family == 'RedHat'
    - debug:
        msg:
          hostname: "{{ inventory_hostname }}"
          distribution: "{{ ansible_distribution }} {{ ansible_distribution_version }}"
          kernel: "{{ kernel.stdout }}"
          boot_time: "{{ uptime_start.stdout }}"
          package_check_rc: "{{ (apt_check.rc if ansible_os_family == 'Debian' else dnf_check.rc) }}"
```

A successful Ansible recap is not enough. Check package-manager health and post-reboot reachability.

## Cleanup

Always delete resources at the end unless the user explicitly asks to keep them.

Cleanup pattern:

1. Query servers by label selector, not by remembered names alone.
2. Delete every server matching the current lab label/purpose/run.
3. Poll the API until no matching servers remain.
4. Report cleanup status precisely.

Example result to report:

```text
Deleted 5 labelled Hetzner servers.
Cleanup verified: no matching servers remain.
```

If cleanup fails, report the exact remaining labelled resource names/IDs privately to the user. Do not put them in public docs or PR bodies.

## Reporting rules

Report precisely:

- role/repo and commit tested,
- Ansible controller path/version,
- OS matrix by distro/version, not private IP,
- every case and return code,
- independent verification results,
- cleanup result,
- blockers and exact failed step if any.

Do not leak:

- cloud API tokens,
- SSH private keys,
- real temporary IPs in public-facing reports,
- internal/private hostnames,
- usernames or credentials,
- full provider state files,
- raw inventory contents if they include IPs or sensitive hostnames.

Use sanitized evidence in PRs/changelogs:

```text
Ubuntu 24.04, Ubuntu 26.04, Rocky 8.10, Rocky 9.8, Rocky 10.x
level-none_reboot-deny rc=0
VERIFY_RC=0
Cleanup verified through provider API
```

Avoid:

```text
<real-ip-address>
<private-fqdn>
<token>
state.json dumps
inventory.ini dumps
```

## Session lessons captured

These were solved during a Hetzner Ansible lab session and should not be rediscovered next time:

1. **Inventory SSH args need quoting in INI.** `ansible_ssh_common_args=-F /path/to/config` failed because the parser split on the space. Use `ansible_ssh_common_args='-F /path/to/config'` in this Hetzner inventory style.
2. **Regenerate inventory from state.** Old IPs and hand-edited host mappings can mismatch OS images. Generate from fresh `state.json` every run.
3. **Do not create host/group name collisions.** Avoid `[rocky8]` when the host is also named `rocky8`; use `[rocky8_bootstrap]`.
4. **Rocky 8 requires raw Python bootstrap.** `python3` is Python 3.6; install `python39` with `raw` before facts/modules and pin `/usr/bin/python3.9`.
5. **Do not install `python39-libselinux` unless proven available.** It was not available in the tested Rocky 8 repo and caused a failed attempt.
6. **`dnf clean all` makes later dnf tasks slow.** Long Rocky 8/Rocky 9/Rocky 10 full updates can take several minutes and download large metadata/packages; check remote `dnf`/`rpm` process state before assuming a hang.
7. **`needs-restarting -r` may show `fatal` in output but be ignored intentionally.** Some roles use this to detect reboot need; inspect play recap/return code before treating it as failure.
8. **Use labels for cleanup, not memory.** Query provider API by label selector and verify no matching servers remain.
9. **Do not commit lab harness artifacts.** Keep `inventory.ini`, `state.json`, `ssh_config`, logs, and temporary reports outside the repo or untracked.
10. **Public docs and PRs need sanitized results.** OS versions, kernels, return codes, and cleanup status are fine; temporary IPs, private hostnames, tokens, usernames, state dumps, and inventory dumps are not.
11. **Never disable SSH host-key checking.** Verify each newly provisioned VM's ED25519 fingerprint through the Hetzner Cloud Console, then use a run-specific `known_hosts` file.

## Final checklist

Before final response:

- [ ] User approved the planned Hetzner setup.
- [ ] Existing labelled resources checked before create.
- [ ] VMs created with labels and run id.
- [ ] Every VM host key verified through the provider console and pinned in the run-specific `known_hosts` file.
- [ ] Inventory generated from current state.
- [ ] Rocky 8 bootstrapped with raw Python 3.9 if present.
- [ ] Ansible ping and facts succeeded for all targets.
- [ ] Requested playbooks/roles were run.
- [ ] Independent verification succeeded or blocker is documented.
- [ ] Cloud resources deleted.
- [ ] Provider API confirms no labelled resources remain.
- [ ] Public-facing report is sanitized.
