# OpenAI Codex OAuth pairing

OpenAI Codex uses OAuth/device authorization. It is not a static API-key-only integration.

## Why manual pairing is required

Hermes stores OAuth state under the Hermes home directory, normally:

```text
/opt/data/auth.json
```

In this Kubernetes setup `/opt/data` lives on the `hermes-home` PVC.

If you delete the namespace and the PVCs, `auth.json` is gone. A fresh rebuild is therefore healthy but unauthenticated for Codex until you pair again.

## Pairing procedure

```bash
export KUBECONFIG=/path/to/kubeconfig
export HERMES_NAMESPACE=hermes

kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

Inside `hermes model`:

1. choose OpenAI Codex / ChatGPT Codex provider;
2. choose the desired model;
3. open the displayed OAuth/device URL in a browser;
4. log in to the OpenAI/ChatGPT account;
5. approve the device authorization;
6. return to the terminal and let Hermes finish.

Do not paste OAuth tokens into manifests, GitHub issues, docs, logs, or chat.

## Verify

```bash
kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-agent -- sh -lc 'ls -l /opt/data/auth.json'
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- hermes auth list openai-codex
```

Expected:

- `/opt/data/auth.json` exists and is non-empty;
- `hermes auth list openai-codex` shows at least one credential entry.

## Preserve auth across rebuilds

Use `maintain.sh backup` before destructive operations:

```bash
./maintain.sh backup ./backups/hermes-$(date -u +%Y%m%dT%H%M%SZ).tgz
```

Restore later:

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.tgz
```
