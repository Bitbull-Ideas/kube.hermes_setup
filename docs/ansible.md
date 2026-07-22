# Persistent Ansible setup

This installer does not need a custom Agent image for a basic Ansible control setup. Use the persistent Python addon venv and the workspace bootstrap examples.

## Install Ansible into the persistent addon venv

The wizard enables the Ansible package, workspace seed, SSH key setup, and `ANSIBLE_CONFIG` together and asks for the package version:

```bash
./setup.sh
```

For manual configuration, select any profile and enable Ansible explicitly:

```bash
cat >> hermes.env <<'EOF'
HERMES_ADDON_PYTHON_VERSION=3.13
HERMES_BOOTSTRAP_PROFILE=personal-assistant
HERMES_ANSIBLE_SETUP=true
HERMES_ANSIBLE_VERSION=14.1.0
HERMES_SSH_SETUP=true
HERMES_BOOTSTRAP_MODE=missing
EOF
ENV_FILE=./hermes.env ./install.sh
```

The packages are installed into `/opt/data/addon-venv`, backed by a uv-managed Python runtime under `/opt/data/uv`. Both paths are PVC-backed and survive Pod recreation. Because the Python runtime is under `/opt/data`, the same Ansible CLI works from the `hermes-agent`, `hermes-dashboard`, and `hermes-webui` containers.

When `HERMES_ANSIBLE_SETUP=true`, `install.sh` adds `ansible==${HERMES_ANSIBLE_VERSION}` to the generated requirements copied into the bootstrap archive. This works with either profile and does not modify a source `requirements.txt`. The system architect profile still defaults Ansible and SSH to enabled; explicit values in `hermes.env` override profile defaults.

For a custom override without the profile system, copy the shared layer and desired profile manually, then point `HERMES_BOOTSTRAP_DIR` at the merged result.

The installer also ensures this Ansible project directory exists on the shared workspace PVC, even when no bootstrap directory is provided:

```text
/workspace/ansible/
```

If `HERMES_BOOTSTRAP_DIR=./bootstrap` is set, the example Ansible files from `bootstrap/workspace/ansible/` are copied there in `missing` mode. If no bootstrap files are present, the init job creates a safe default `ansible.cfg`, `inventory/hosts.ini`, and the standard subdirectories.

## Verify

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- ansible --version
kubectl -n <namespace> exec deploy/hermes-dashboard -- ansible --version
kubectl -n <namespace> exec deploy/hermes-webui -- ansible --version
kubectl -n <namespace> exec deploy/hermes-webui -- python --version
kubectl -n <namespace> exec deploy/hermes-agent -- sh -lc 'echo "$ANSIBLE_CONFIG"; ls -la /workspace/ansible'
kubectl -n <namespace> exec deploy/hermes-agent -- sh -lc 'cd /workspace/ansible && ansible-inventory --list'
kubectl -n <namespace> exec deploy/hermes-agent -- sh -lc 'cd /workspace/ansible && ansible-playbook playbooks/ping-local.yml'
```

If an interactive shell resets `PATH`, use:

```bash
export PATH=/opt/data/addon-venv/bin:$PATH
```

or call `/opt/data/addon-venv/bin/ansible-playbook` explicitly.

## SSH and persistence

The persistent HOME feature sets `HOME=/opt/data` for the Agent, Dashboard, and WebUI containers. With `HERMES_SSH_SETUP=true`, the init job prepares `/opt/data/.ssh` and creates `/opt/data/.ssh/id_ed25519` only if it is missing. Install the public key on managed hosts:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- cat /opt/data/.ssh/id_ed25519.pub
```

Keep host key checking enabled. Maintain `/opt/data/.ssh/known_hosts` or use reviewed per-host `accept-new` entries in `/opt/data/.ssh/config`; do not set global `StrictHostKeyChecking=no`.

## Where things are mounted

| Container | `/opt/data` | `/workspace` | Notes |
|---|---|---|---|
| `hermes-agent` | mounted read/write from `hermes-home` PVC | mounted read/write from `hermes-workspace` PVC | Runs tools, terminal commands, addon venv, SSH, Ansible. |
| `hermes-dashboard` | mounted read/write from `hermes-home` PVC | mounted read/write from `hermes-workspace` PVC | Dashboard `/files` is rooted at `/workspace`. |
| `hermes-webui` | mounted read/write from `hermes-home` PVC | mounted read/write from `hermes-workspace` PVC | Chat UI state lives under `/opt/data/webui`; uploaded/workspace files are under `/workspace`. |
| `hermes-browser` | not mounted | not mounted | Stateless Browserless/Chromium service. |
| `hermes-init-config` job | mounted read/write | mounted read/write | Seeds `/opt/data`, `/workspace`, addon venv, SSH, and Ansible defaults. |

Important paths:

```text
/opt/data/uv                        # persistent uv binary, cache helper path, and managed Python installs
/opt/data/addon-venv                # persistent uv-created Python addon venv
/opt/data/.ssh                      # persistent SSH keys/config/known_hosts
/opt/data/ansible/tmp               # Ansible local temp
/opt/data/ansible/cp                # SSH ControlPath directory
/workspace/ansible                  # visible Ansible project directory
/workspace/ansible/ansible.cfg      # default ANSIBLE_CONFIG
/workspace/ansible/inventory        # inventories
/workspace/ansible/playbooks        # playbooks
/workspace/ansible/roles            # visible galaxy roles install target
/workspace/ansible/collections      # visible galaxy collections install target
/workspace/ansible/group_vars       # group variables
/workspace/ansible/host_vars        # host variables
```

The Agent, Dashboard, and WebUI deployments set:

```text
ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg
HOME=/opt/data
XDG_CONFIG_HOME=/opt/data/.config
XDG_CACHE_HOME=/opt/data/.cache
LANG=C.UTF-8
LC_ALL=C.UTF-8
```

The UTF-8 locale is required because Ansible refuses to start when Python reports no locale encoding inside the WebUI container.

## Roles and collections

The default `ansible.cfg` uses absolute paths so installs are visible in `/workspace/ansible`:

```ini
roles_path = /workspace/ansible/roles:/opt/data/ansible/roles
collections_path = /workspace/ansible/collections:/opt/data/ansible/collections
local_tmp = /opt/data/ansible/tmp
```

Install roles into the visible workspace path:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- sh -lc   'ansible-galaxy role install -r /workspace/ansible/roles/requirements.yml -p /workspace/ansible/roles'
```

Install collections into the visible workspace path:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- sh -lc   'ansible-galaxy collection install -r /workspace/ansible/collections/requirements.yml -p /workspace/ansible/collections'
```

These targets are on the `hermes-workspace` PVC, so they are visible from Dashboard `/files`, WebUI workspace access, and the Agent shell.

Note: `ansible-galaxy collection init --init-path /workspace/ansible/collections local.visible` creates a development tree at `/workspace/ansible/collections/local/visible`; `ansible-galaxy collection install -p /workspace/ansible/collections ...` creates the install tree below `/workspace/ansible/collections/ansible_collections/...`. Both are intentionally under `/workspace/ansible/collections` so operators can inspect them.
