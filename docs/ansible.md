# Persistent Ansible setup

This installer does not need a custom Agent image for a basic Ansible control setup. Use the persistent Python addon venv and the workspace bootstrap examples.

## Install Ansible into the persistent addon venv

Copy the example bootstrap tree and point the installer at the Ansible requirements file:

```bash
cp -a examples/bootstrap ./bootstrap
cat >> hermes.env <<'EOF'
HERMES_ADDON_REQUIREMENTS=./bootstrap/requirements.txt
HERMES_ADDON_VENV=/opt/data/addon-venv
HERMES_BOOTSTRAP_DIR=./bootstrap
HERMES_BOOTSTRAP_MODE=missing
HERMES_HOME_AS_HOME=true
HERMES_SSH_SETUP=true
EOF
ENV_FILE=./hermes.env ./install.sh
```

The packages are installed into `/opt/data/addon-venv`, which is PVC-backed and survives Pod recreation.

The installer also ensures this Ansible project directory exists on the shared workspace PVC, even when no bootstrap directory is provided:

```text
/workspace/ansible/
```

If `HERMES_BOOTSTRAP_DIR=./bootstrap` is set, the example Ansible files from `bootstrap/workspace/ansible/` are copied there in `missing` mode. If no bootstrap files are present, the init job creates a safe default `ansible.cfg`, `inventory/hosts.ini`, and the standard subdirectories.

## Verify

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- ansible --version
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

The Agent HOME/SSH feature sets `HOME=/opt/data` and prepares `/opt/data/.ssh`. With `HERMES_SSH_SETUP=true`, the init job creates `/opt/data/.ssh/id_ed25519` only if it is missing. Install the public key on managed hosts:

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
/opt/data/addon-venv                # persistent Python addon venv
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

The Agent deployment sets:

```text
ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg
```

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
