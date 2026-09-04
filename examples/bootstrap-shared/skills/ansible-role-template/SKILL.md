---
name: ansible-role-template
description: Create OS-aware Ansible roles from a deterministic template.
version: 0.1.0
author: Chris Ruettimann (joe-speedboat), Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Ansible, roles, templates, operating systems, automation]
    related_skills: [hermes-workspace-ansible, ansible-role-pr-and-live-verification]
    related_skill_classifications:
      hermes-workspace-ansible: bundled
      ansible-role-pr-and-live-verification: external-runtime
---

# Ansible Role Template Skill

Use this skill to create or refactor reusable Ansible roles based on the
`joe-speedboat/ansible.template` design. The defining feature is deterministic,
OS-aware task dispatch: logical numbered task basenames are selected from the
most specific distribution/version directory and fall back to shared tasks.
This skill creates source and tests; it does not authorize changes on managed
production targets. The source template is a role scaffold, not a Hermes skill:
its README, dispatcher, demo tasks, and test harness must be converted into a
real role rather than installed as an agent skill.

## When to Use

Use when:

- Creating a new Ansible role from the Bitbull role template.
- Refactoring a role to separate shared behavior from OS-specific behavior.
- Supporting Debian, Ubuntu, Rocky, AlmaLinux, RHEL, or other fact-selected targets.
- Reviewing task placement, fallback behavior, or basename shadowing.

Do not use for a one-off playbook with no reusable role structure, or for
applying a role to production without the applicable target authorization and
change-safety workflow.

## Prerequisites

- An active workspace containing an `ansible/` directory.
- The template repository or an existing role copied from it.
- Ansible available through the workspace's documented runtime.
- Target OS facts available through fact gathering for live execution.
- Ansible Vault or an approved secret-management mechanism for credentials and
  private certificate material.

## Template Contract

Preserve these dispatcher files unless intentionally changing dispatch behavior:

```text
tasks/main.yml
tasks/include-file.yml
```

The dispatcher:

1. Maps AlmaLinux, Rocky, and Red Hat to the logical family `rhelAll`.
2. Discovers numbered task files below `tasks/`.
3. Extracts unique basenames and sorts them.
4. Selects one implementation per basename using `with_first_found`.

The normal lookup order is:

```text
tasks/<distribution>-<full-version>/<basename>
tasks/<distribution>-<major-version>/<basename>
tasks/<distribution>/<basename>
tasks/rhelAll-<full-version>/<basename>
tasks/rhelAll-<major-version>/<basename>
tasks/rhelAll/<basename>
tasks/<ansible_os_family>/<basename>
tasks/shared/<basename>
```

`rhelAll` candidates apply to AlmaLinux, Rocky, and Red Hat. The final
`shared/` candidate is the cross-platform fallback.

## Shared-vs-OS Placement Rule

`tasks/shared/` must contain behavior that is valid on every supported OS.
It must not contain OS selectors or platform-specific paths, package managers,
service-manager branches, or distribution names.

Put platform-specific behavior in the corresponding directory:

```text
tasks/Debian/
tasks/Ubuntu/
tasks/rhelAll/
tasks/Rocky-9/
tasks/RedHat/
```

Examples:

- `apt` and Debian site enablement belong under `tasks/Debian/`.
- `dnf` and RHEL-family repository/package behavior belong under `tasks/rhelAll/`.
- `/etc/nginx/sites-enabled` is Debian-specific.
- `/etc/nginx/conf.d` may be RHEL-specific when the role chooses that layout.
- Generic service operations using `ansible.builtin.service` may be shared.
- Generic file ownership, templating, and certificate operations may be shared.

A shared file may contain variable-based behavior such as an optional TLS flag.
That is feature selection, not OS selection. Do not place `when:
ansible_os_family == ...` in a shared task file; split the file by OS instead.

## Basenames and Shadowing

Use two-digit numeric prefixes for logical execution order:

```text
00_validate.yml
10_prep.yml
20_install.yml
20_configure.yml
30_service.yml
```

The basename is the logical task identity. If both files exist:

```text
tasks/shared/20_install.yml
tasks/Ubuntu/20_install.yml
```

Ubuntu runs only `tasks/Ubuntu/20_install.yml`; the shared file is shadowed.
This is fallback selection, not additive inheritance.

If behavior must run everywhere, give it a distinct basename:

```text
tasks/shared/15_common_setup.yml
tasks/Ubuntu/20_install.yml
tasks/shared/30_service.yml
```

Avoid accidental duplicate logical basenames unless the replacement semantics
are deliberate and documented.

## Repository Interpretation

`joe-speedboat/ansible.template` is a reusable Ansible role scaffold. It is
special because `tasks/main.yml` discovers numbered task basenames and
`tasks/include-file.yml` selects the first matching distribution/version,
OS-family, or shared implementation. It is not a service role, collection,
Ansible module, or additive inheritance system.

When converting it into a real role:

- Replace demo variables and debug tasks.
- Update `meta/main.yml` with the real namespace, role name, description,
  supported platforms, and Galaxy tags.
- Rewrite the role README for the actual behavior, variables, OS matrix, and
  validation commands.
- Retain the dispatcher files unless changing dispatch behavior intentionally.
- Keep `.gitstay` only for empty OS directories that must remain in Git.
- Replace the demo handler, files, templates, and tests with role-specific content.

The template's dispatcher is a deliberate compatibility layer for local Ansible,
Galaxy/AWX/AAP role paths, and test harnesses. It searches for the installed
role's `tasks/main.yml`; a checkout-only invocation is not sufficient proof.

## Role Design Rules

Separate controls that have different meanings. For example, use independent
variables for package installation, service management, and configuration
management rather than making `manage_service: false` also suppress package
installation. Document every public default.

Use fully qualified builtin modules. Install command dependencies in the
platform-specific installation task: if shared TLS logic invokes `openssl`,
Debian and RHEL-family install tasks must install the appropriate OpenSSL
package. Use stable ownership and modes; private keys are normally `0600` and
certificates `0644`.

For certificates:

- Require certificate and private-key source paths as a complete pair.
- Keep source material outside Git, preferably in Vault or an approved secret
  store; never place private keys, tokens, or passwords in the role.
- Treat self-signed certificates as internal/bootstrap material unless trust is
  distributed separately.
- Make self-signed generation idempotent and avoid silently rotating an existing
  key merely because variables changed.
- Validate the rendered service configuration before reload or restart.

Use shared tasks for platform-neutral operations such as generic file creation,
certificate handling, templating, and a common `ansible.builtin.service` call.
Use OS directories for package managers, repository setup, filesystem layout,
site enablement, init-system differences, and platform-specific paths.

## Test Harness and Verification Details

Test the role under the basename expected by `role_path | basename`, normally:

```text
harness/roles/<role-name>/
```

A symlink may resolve to its target basename and cause the dispatcher to search
the wrong path. If a symlink-based harness fails role discovery, use a real
copy or directory with the expected role name, and document why. Do not treat
syntax-check success as installation or runtime success.

Minimum local gates:

- Parse every YAML file.
- Run syntax checks for every test playbook.
- Exercise at least one Debian-family and one RHEL-family dispatch path with a
  valid controller interpreter.
- Verify `tasks/shared/` contains no OS selectors or platform-specific paths.
- Run `git diff --check` and a focused secret scan.
- Where installation is disabled in a smoke test, explicitly state that package,
  service, and live configuration behavior was not tested.

For live QA, independently verify package state, enabled/running service,
rendered configuration, configuration-test command, HTTP/TLS response,
certificate permissions, and a second converge with no unexpected changes.
Record which OS versions were actually reachable; inventory presence or syntax
selection is not evidence of live coverage.

## Live Lab Safety

Provisioning Hetzner VMs or other disposable infrastructure costs money and is a
side effect. Before provisioning, present the OS matrix, location, server type,
rough cost/runtime, labels, and cleanup plan, then wait for explicit user
approval. Check for existing resources with the same purpose/run label first.

Use current provider API data rather than assuming image, location, or server
type availability. Select the correct architecture: generic role QA normally
requires x86_64 images and x86 server types. Generate inventory from current
server state, never reuse stale IP mappings, and keep inventory, SSH config,
credentials, and logs outside the role repository.

Verify the actual SSH key attached to each VM matches the key available to
Ansible. Diagnose connection refusal, host-key policy, and public-key
authentication separately. Never print private keys. If authentication fails,
report the concrete blocker and do not claim live role verification.

Label every resource with purpose, owner, repository/role, and run ID. In a
cleanup path delete every resource created by the run, poll until the provider
confirms removal, and report cleanup separately from test success. Do not
destroy unrelated resources or manually managed lab systems.

## Procedure

1. **Inspect the workspace.** Use `read_file`, `search_files`, and `terminal` to
   read workspace instructions, inspect the existing `ansible/` layout, and
   establish the exact role destination. Completion criterion: every planned
   file is under the active Ansible workspace and unrelated changes are known.
2. **Classify the role.** Identify supported distributions, package managers,
   service names, configuration paths, and genuinely shared behavior. Completion
   criterion: an OS matrix and shared/OS task map are explicit before editing.
3. **Create the role structure.** Use `write_file` for role files and preserve
   the template dispatcher contract. Completion criterion: metadata, defaults,
   handlers, templates, tasks, README, and tests have intentional contents.
4. **Place tasks correctly.** Put package installation and platform paths in OS
   directories; keep shared tasks OS-neutral. Completion criterion: searching
   every file under `tasks/shared/` finds no OS selectors or OS-specific paths.
5. **Define variables.** Put user-overridable values in `defaults/main.yml` and
   fixed internal maps/constants in `vars/main.yml`. Separate installation,
   service management, and configuration toggles when their behavior differs.
   Completion criterion: each public variable is documented and no secret is
   stored in the role.
6. **Implement safe configuration.** Use fully qualified builtin modules, stable
   file modes, handlers, configuration validation before reload, and explicit
   certificate/key handling. Treat self-signed certificates as bootstrap or
   internal trust material unless an approved trust process exists.
7. **Document use cases.** Add a role README with supported platforms, variable
   reference, task-dispatch explanation, HTTP/TLS examples, and test commands.
   Completion criterion: a reviewer can use the role without reading the source.
8. **Validate locally.** Run YAML parsing, syntax checks for every test playbook,
   a check-mode path where meaningful, `git diff --check`, and a focused scan for
   secrets and forbidden shared-task selectors. Completion criterion: checks
   pass or every blocker is reported explicitly.
9. **Validate live only when authorized.** For a disposable lab, use the
   `hetzner-ansible-lab` workflow: obtain explicit provisioning approval, label
   resources, verify facts, run install/configuration/idempotency checks, test
   service and HTTP/TLS behavior independently, and delete every temporary VM.
10. **Report the artifact.** State the exact role path, changed files, checks
    performed, live targets actually reached, cleanup status, and limitations.

## Example Layout

```text
tasks/
├── main.yml
├── include-file.yml
├── Debian/
│   ├── 10_install.yml
│   ├── 20_platform.yml
│   └── 30_configure.yml
├── rhelAll/
│   ├── 10_install.yml
│   ├── 20_platform.yml
│   └── 30_configure.yml
└── shared/
    ├── 00_validate.yml
    ├── 20_content.yml
    ├── 20_tls.yml
    └── 40_service.yml
```

For an nginx role, `shared/20_content.yml` can create the document root and
index page. `Debian/20_platform.yml` can remove the Debian default site.
`Debian/30_configure.yml` can manage `sites-available` and `sites-enabled`,
while `rhelAll/30_configure.yml` manages `conf.d`. No shared task needs to
inspect `ansible_os_family`.

## Verification

- Parse every YAML file with a YAML parser.
- Run `ansible-playbook --syntax-check` for the role's test playbooks.
- Run the dispatcher in check mode for at least one Debian-family and one
  RHEL-family fact set, using a valid controller interpreter.
- Search `tasks/shared/` for `ansible_os_family`, `ansible_distribution`,
  `Debian`, `RedHat`, `apt`, `dnf`, `yum`, and platform-specific paths.
- Verify each selected OS implementation is included by the dispatcher.
- For live QA, verify package state, enabled/running service, rendered config,
  nginx syntax or equivalent service validation, HTTP/TLS response, certificate
  permissions, and a second converge with no unexpected changes.
- Confirm temporary lab resources are absent through the provider API after QA.

## Pitfalls

1. Putting an OS conditional in `tasks/shared/` defeats the template's main
   abstraction; split the task into OS directories.
2. Expecting shared and OS-specific files with the same basename to both run;
   the first match wins.
3. Naming a task file without a two-digit prefix; the dispatcher will not find
   it if it does not match the numbered-file pattern.
4. Coupling package installation to service management when callers need those
   controls independently.
5. Invoking a command such as `openssl` without installing its package in the
   relevant OS-specific install task.
6. Generating a self-signed certificate on every run; preserve an existing key
   unless controlled certificate rotation is explicitly designed.
7. Testing only the checkout path; the dispatcher expects an installed role
   under a supported `roles/` path.
8. Using symlinks in a harness without checking how `role_path | basename` is
   resolved; a real directory copy may be needed.
9. Claiming multi-OS coverage from syntax checks alone; live facts and behavior
   must be verified separately.
10. Leaving temporary inventories, credentials, logs, or lab VMs after testing.

## Completion Checklist

- [ ] Role is under the active Ansible workspace.
- [ ] Dispatcher contract is preserved or its intentional changes are documented.
- [ ] `tasks/shared/` contains no OS selectors or platform-specific behavior.
- [ ] Package and platform-path tasks are in OS-specific directories.
- [ ] Logical basenames and shadowing behavior are documented.
- [ ] Defaults, metadata, handlers, templates, README, and tests are complete.
- [ ] YAML and syntax checks pass.
- [ ] Check-mode dispatch was exercised for Debian and RHEL families where possible.
- [ ] Secret scan and `git diff --check` passed.
- [ ] Live lab results and provider cleanup are separately verified when used.
- [ ] Limitations are reported honestly.
