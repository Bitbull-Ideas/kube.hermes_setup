# Operations guide

## Status

```bash
./maintain.sh status
./doctor.sh
```

## Restart

```bash
./maintain.sh restart
```

## Upgrade

Pin image tags in `hermes.env`, then run:

```bash
./install.sh
./doctor.sh
```

For a pull-latest style restart:

```bash
./maintain.sh upgrade
```

## Backup

```bash
mkdir -p backups
./maintain.sh backup ./backups/hermes-$(date -u +%Y%m%dT%H%M%SZ).tgz
```

The archive contains:

```text
/opt/data
/workspace
```

This includes OAuth state, sessions, skills, memories, workspace files, and WebUI state. Treat backups as sensitive.

## Restore

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.tgz
./doctor.sh
```

## Password rotation

```bash
BASIC_AUTH_USER=admin DASHBOARD_AUTH_USER=admin ./maintain.sh rotate-passwords
```

The command prints generated passwords. Store them in a password manager.

## Browser token rotation

```bash
./maintain.sh rotate-browser-token
./doctor.sh
```

## Codex re-authentication

```bash
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

See `docs/codex-auth.md`.
