---
name: github-setup-access
description: Use when configuring GitHub access for a Hermes Kubernetes installation that should read public repositories and contribute pull requests without access to private repositories. Guide the user through a dedicated low-privilege GitHub account, a classic PAT limited to public_repo, secure placement in /opt/data/.env, and non-disclosing verification.
version: 2.0.1
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [github, authentication, kubernetes, token, pull-requests]
    related_skills: [github-auth, github-pr-workflow]
---

# GitHub Setup Access

## Overview

Configure a Hermes Agent running in Kubernetes to read public GitHub repositories and create pull requests while excluding private-repository access. The tested pattern is:

1. Use a dedicated GitHub account for Hermes.
2. Give that account no private-repository, organization, or administrative access unless explicitly required later.
3. Create a **personal access token (classic)** with only the nested `public_repo` scope.
4. Store it as `GITHUB_TOKEN` in `/opt/data/.env` on the persistent Hermes home PVC.
5. Verify identity and effective repository permissions without printing the token.

This is a **low-privilege public-repository contributor**, not a strictly read-only identity. Creating a fork, pushing a feature branch, and opening a pull request requires write operations. The security boundary comes from using a dedicated account with no private access and a token restricted to public repositories.

## When to Use

Use this skill when the user wants Hermes to:

- Read arbitrary public GitHub repositories.
- Push branches to public repositories where the dedicated account has write access.
- Fork public repositories and submit pull requests where it lacks direct write access.
- Avoid access to private repositories.
- Persist GitHub CLI/API credentials in the Kubernetes-based `kube.hermes_setup` installation.

Do not use this pattern when:

- Access must be genuinely read-only; use unauthenticated public reads or a token with metadata/content read permissions and do not promise PR creation.
- Access must be limited to one known repository or one resource owner; prefer a fine-grained PAT.
- A long-lived organization integration is required; prefer a GitHub App with narrowly scoped installation permissions.
- The user requests private-repository access; reassess account membership and token scope explicitly rather than broadening this token silently.

## 1. Establish the Account Boundary

Recommend a dedicated GitHub user such as `hermes-example` rather than a maintainer's personal account. Configure that account with:

- A verified email address.
- Two-factor authentication.
- No ownership or membership in organizations unless directly needed.
- No invitations to private repositories.
- No saved payment or unrelated personal data.
- A recognizable profile description so maintainers know PRs are automation-assisted.

The token can only exercise access already held by its owner, but a classic token applies broadly within its scope. Keeping the account itself isolated is therefore part of least privilege.

Before proceeding, state this limitation clearly:

> `public_repo` is not read-only. It permits public-repository write actions available to this GitHub account. We constrain risk by using a dedicated account with no private-repository access and by granting no scopes beyond `public_repo`.

This step is complete when the user understands the write requirement and the dedicated account has no unintended repository or organization access.

## 2. Create the Least-Privilege Token That Supports Public PRs

Open the classic token creation page while signed in as the dedicated account:

```text
https://github.com/settings/tokens/new
```

Choose:

| Field | Recommended value |
|---|---|
| Note | `Hermes public repository PR access` |
| Expiration | 30–90 days; shorter is safer |
| Scopes | Only the nested `public_repo` checkbox |

The selected scope must look like:

```text
repo
└── public_repo
```

Select **only** `public_repo`; do not select the parent `repo` checkbox. Leave every unrelated scope unchecked, including:

- `repo` (the parent scope, which includes private repositories)
- `workflow`
- `delete_repo`
- `admin:org`, `write:org`, and `read:org`
- `admin:repo_hook`
- `write:packages`
- `gist`
- `user`

Why classic rather than fine-grained for this use case: a fine-grained PAT is bound to one resource owner and selected repositories, and may not support the desired broad contribution workflow across arbitrary public repositories. The classic `public_repo` scope was validated for this public-repository PR workflow, but it is broader than a repository-specific token.

If an organization enforces SAML SSO or token policies, the user may need to authorize the token for that organization. Organization policy can still reject classic PATs. Do not work around such policy; use a repository-specific fine-grained PAT or a GitHub App if required.

Treat the generated token like a password. The user must not paste it into chat, a repository, a Git remote URL, shell output, or public documentation.

This step is complete when the token has only `public_repo`, has an expiration, and no private-repository scope is selected.

## 3. Install the Token in the Kubernetes Hermes Home

In `kube.hermes_setup`, `/opt/data` is the persistent Hermes home shared by the relevant runtime containers. Store the token in:

```text
/opt/data/.env
```

Use the Agent deployment and replace `<namespace>` with the actual Hermes namespace:

```bash
kubectl -n <namespace> exec -it deploy/hermes-agent -- /bin/bash
```

Inside the pod, for a first-time token installation:

```bash
umask 077
touch /opt/data/.env
chmod 600 /opt/data/.env
echo 'GITHUB_TOKEN=***' >> /opt/data/.env
chmod 600 /opt/data/.env
exit
```

Replace `***` locally with the actual token. Never ask the user to send the token through chat. The quoted `echo` command is simple and matches the tested setup, but interactive shell history may retain it. When shell-history exposure matters, disable history for the command or use a hidden prompt instead:

```bash
kubectl -n <namespace> exec -it deploy/hermes-agent -- /bin/bash
set +o history
umask 077
read -r -s -p 'GitHub token: ' GITHUB_TOKEN; printf '\n'
touch /opt/data/.env
chmod 600 /opt/data/.env
if grep -q '^GITHUB_TOKEN=' /opt/data/.env; then
  sed -i '/^GITHUB_TOKEN=/d' /opt/data/.env
fi
printf 'GITHUB_TOKEN=%s\n' "$GITHUB_TOKEN" >> /opt/data/.env
unset GITHUB_TOKEN
chmod 600 /opt/data/.env
exit
```

Before appending with `echo`, check whether the variable already exists without printing its value:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- \
  sh -lc "grep -q '^GITHUB_TOKEN=' /opt/data/.env 2>/dev/null"
```

- Exit code `0`: an assignment already exists; replace it rather than appending a duplicate.
- Exit code `1`: no assignment exists; first-time append is appropriate.

Do not store the token in:

- The repository's `hermes.env`.
- `examples/hermes.env.example`.
- `examples/bootstrap/` in a public checkout.
- `/workspace`.
- Kubernetes manifests or ConfigMaps.
- A Git remote URL.

`/opt/data/.env` is persistent and may be included in Hermes backups. Treat those backups as secrets. A copied `examples/bootstrap/` tree must not contain this real token.

This step is complete when exactly one `GITHUB_TOKEN` assignment exists in `/opt/data/.env`, the file mode is `0600`, and no token value was disclosed.

## 4. Make the Credential Available

A newly written `.env` file may not retroactively alter the environment of already-running processes. Prefer starting a new Hermes session after installation. If the deployment or local integration explicitly reads `/opt/data/.env` only at process startup, restart the relevant deployments through the repository's supported operation:

```bash
./maintain.sh restart
```

Do not restart a production installation without user authorization. Do not inject the token into a Kubernetes ConfigMap. If a direct shell test is needed, source `/opt/data/.env` only inside that shell and never enable command tracing:

```bash
set +x
set -a
. /opt/data/.env
set +a
```

This step is complete when the intended Hermes process can read `GITHUB_TOKEN` without displaying it.

## 5. Verify Without Leaking the Token

First verify only presence and file permissions:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- sh -lc '
  test -s /opt/data/.env
  test "$(stat -c %a /opt/data/.env)" = 600
  grep -q "^GITHUB_TOKEN=" /opt/data/.env
  printf "GitHub token configuration present with mode 600\n"
'
```

Then verify the authenticated identity through the GitHub API while suppressing the token:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- sh -lc '
  set +x
  set -a
  . /opt/data/.env
  set +a
  python3 - <<"PY"
import json, os, urllib.request

token = os.environ.get("GITHUB_TOKEN")
assert token, "GITHUB_TOKEN is not set"
request = urllib.request.Request(
    "https://api.github.com/user",
    headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "Hermes-Agent",
    },
)
with urllib.request.urlopen(request, timeout=30) as response:
    data = json.load(response)
print("Authenticated GitHub account:", data["login"])
PY
'
```

Do not print `/opt/data/.env`, run `env`, enable `set -x`, or include authorization headers in logs. For a target repository, inspect the API's effective `permissions` object and report booleans such as `pull=true` or `push=true`; never infer write access merely because a public clone succeeds.

Verification is complete only when:

- The authenticated login is the intended dedicated account.
- Public repository reads succeed.
- The account has no unintended private-repository or organization access.
- A feature-branch push succeeds where the account has direct write access, or a fork-based workflow succeeds where it does not.
- PR creation is verified with the returned URL.

## 6. Contribution Behavior

For each public repository:

1. Read its `AGENTS.md`, `CONTRIBUTING.md`, security policy, license, and repository-specific instructions.
2. If the account has direct push permission, create a feature branch; never push directly to the default branch unless explicitly authorized.
3. If direct push is unavailable, fork the repository under the dedicated account, push the branch to the fork, and open a cross-repository PR.
4. Never merge, close, approve, or rewrite another contributor's PR without explicit authorization.
5. Do not broaden token scopes because one repository disallows the contribution path. Diagnose repository, fork, branch-protection, organization, and account-policy restrictions first.

Public readability does not guarantee that a PR can be created. Archived repositories, disabled forks, blocked accounts, organization rules, abuse controls, or disabled pull requests may prevent contribution.

## 7. Rotation and Revocation

Set an expiration reminder. Before expiry:

1. Create a replacement classic PAT with only `public_repo`.
2. Replace the single `GITHUB_TOKEN` assignment in `/opt/data/.env` without printing either value.
3. Start a new session or perform an authorized restart if required.
4. Verify the dedicated account identity and one representative public repository.
5. Revoke the old token at `https://github.com/settings/tokens`.

If the token may have leaked, revoke it immediately, inspect recent account activity, rotate it, and check open branches and PRs created by the account.

## Common Pitfalls

1. **Calling `public_repo` read-only.** It enables public-repository write operations. The dedicated account boundary is essential.
2. **Selecting parent `repo`.** That can expose private repositories. Select only nested `public_repo`.
3. **Using a fine-grained PAT for arbitrary public repositories.** Fine-grained tokens are resource-owner and repository constrained; use them when that narrower model fits.
4. **Appending duplicate assignments.** Check for `^GITHUB_TOKEN=` and replace the old line.
5. **Leaking the token in chat or logs.** Verify presence, identity, and permission booleans—not the token string.
6. **Embedding credentials in the remote URL.** URLs can appear in configuration and diagnostics. Use an askpass helper, credential manager, or API bearer header without logging.
7. **Committing `.env`.** Keep the real credential only in `/opt/data/.env`; sanitized examples must contain placeholders.
8. **Assuming a public repository is writable.** Use a fork-based PR when direct push is not granted.
9. **Forgetting backups.** `/opt/data/.env` can be present in PVC backups; protect and retain them as secrets.
10. **Restarting automatically.** Ask before disrupting deployments; a new session may be sufficient.

## Verification Checklist

- [ ] A dedicated GitHub account is used and has no unintended private access
- [ ] The user was told that PR creation requires write operations
- [ ] Token type is personal access token (classic)
- [ ] Only nested `repo -> public_repo` is selected
- [ ] Parent `repo`, `workflow`, organization, package, hook, gist, and user scopes are absent
- [ ] Token has a short, intentional expiration
- [ ] Exactly one `GITHUB_TOKEN` assignment exists in `/opt/data/.env`
- [ ] `/opt/data/.env` has mode `0600`
- [ ] No token value was printed, committed, logged, or pasted into chat
- [ ] Authenticated login matches the intended dedicated account
- [ ] Effective repository permissions were checked rather than assumed
- [ ] Direct-branch or fork-based PR behavior was selected correctly
- [ ] Rotation/revocation expectations were explained
