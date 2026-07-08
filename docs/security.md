# Security notes

## Do not commit secrets

Never commit:

- `hermes.env`
- rendered manifests under `.rendered/`
- backups
- kubeconfigs
- OAuth files such as `auth.json`
- tokens/passwords/API keys

The repository `.gitignore` excludes the common local files, but operators are still responsible for review before commit.

## Browserless/CDP

Browserless is powerful: it can fetch websites from inside your cluster. This repository therefore:

- exposes Browserless as `ClusterIP` only;
- uses a token;
- stores the CDP URL in a Kubernetes Secret;
- injects `BROWSER_CDP_URL` into Hermes containers;
- restricts access using NetworkPolicy.

The expected redacted endpoint is:

```text
ws://hermes-browser:3000/chromium?token=<redacted>
```

Never print the full value in logs or docs.

## Ingress authentication

Use outer Ingress BasicAuth for the WebUI and dashboard if they are reachable from untrusted networks.

The dashboard also has its own internal BasicAuth provider.

## TLS

Terminate TLS at your Ingress controller. This template supports Ingress TLS references but does not manage certificates.

## Backups

Backups include OAuth state and possibly user/session data. Store them encrypted and restrict access.
