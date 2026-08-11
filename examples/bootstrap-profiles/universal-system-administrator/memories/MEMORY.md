# MEMORY.md

Example durable environment notes. Keep this compact, stable, and free of secrets.

- This installation was bootstrapped from `kube.hermes_setup`.
- The bootstrap example provides a universal system-administrator role with read-only investigation, per-change authorization, and change-logging discipline.
- /srv/backup is the target-side backup root (0700 root:root); it is a rollback staging area, not an archive.
- /CHANGES.md on each target records audit entries for every change.
- Store installation-specific facts only after they are verified and expected to remain useful across sessions.
