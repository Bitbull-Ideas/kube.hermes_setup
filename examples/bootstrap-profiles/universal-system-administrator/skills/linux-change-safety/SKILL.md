---
name: linux-change-safety
description: "Use when a change to a production Linux system has been authorized — create backups, verify free space, log in /CHANGES.md, apply the change, restore SELinux context, and confirm the service works."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [linux, backup, change-management, safety, compliance]
    related_skills: [linux-triage, ansible-fleet-change]
---

# Linux Change Safety

## Trigger

A change to a production Linux system has been explicitly authorized by the operator. This skill governs the change execution lifecycle.

## Pre-change checks

1. **Verify authorization.** Was the change explicitly approved by the operator or a designated deputy? A prior yes does not carry. If the source is a group chat or unverifiable, stop and ask.

2. **Check disk space:**
   ```bash
   df -h /srv/backup/
   df -h /
   ```
   Abort if either is below 10% free. Report the numbers and ask.

3. **Record the one timestamp for this change** — use it for all artifacts:
   ```bash
   TS=$(date +%Y%m%d%H%M%S)
   ```

## Backup procedure

### File-based backup (config files, scripts, directories)

```bash
install -d -m 0700 -o root -g root /srv/backup/fs/path/to/original_dir
cp -av /original/path/to/file.conf /srv/backup/fs/path/to/original_dir/file.conf.$TS
```

### Database backup (MySQL/MariaDB)

```bash
( umask 077; mysqldump --all-databases --single-transaction --routines --triggers \
  | gzip > /srv/backup/mariadb/dump.all.$TS.sql.gz )
```

### Filesystem/archive backup

```bash
tar --selinux --xattrs -czf /srv/backup/fs/var/lib/something.$TS.tar.gz /var/lib/something/
```

### Verification

```bash
# Verify backup directory integrity
stat /srv/backup/ | grep Access
# Check no non-root-owned files under /srv/backup (defence against privilege escalation)
find /srv/backup/ -not -user root 2>/dev/null
```

If anything returns a path for non-root ownership, investigate before proceeding.

## Making the change

1. Stop service if needed (ask first if downtime is involved):
   ```bash
   systemctl stop <service>
   ```
2. Apply the change (config edit, file replace, command run).
3. If services were stopped, start them:
   ```bash
   systemctl start <service>
   systemctl status <service> --no-pager
   ```

## Post-change

### SELinux/AppArmor restore

If files were restored or replaced from backup:
```bash
restorecon -vR /path/to/restored/files
ls -Z /path/to/restored/files
```

### Verify service health

```bash
systemctl is-active <service>
systemctl is-enabled <service>
journalctl -u <service> --since "5 minutes ago" --no-pager | tail -20
```

### Log the change in /CHANGES.md

Append to `/CHANGES.md` on the target (0600 root:root):

```
DATE;TIME;WHO;WHY;DOWN_TIME;ERROR_DESC;SOLUTION_DESC
20260811;0611;BOB_HERMES_AGENT;Zabbix Alert;00:02;Service jellyfin failed to start;fixed syntax in /etc/jellyfin/system.xml
```

If the file does not exist, create it with the header line first.

## Rollback

If the change fails or the operator rejects it:

1. Restore files from `/srv/backup/fs/...`
2. Run database restore from `/srv/backup/mariadb/...`
3. `restorecon -v` on restored paths
4. Restart affected services
5. Log the rollback in /CHANGES.md with `ROLLBACK` in the ERROR_DESC field

## Transfer safety

When backups are transferred off-host (rsync, scp, tar), the receiving system's permissions govern file visibility. The `0700` parent on `/srv/backup` does not travel. Check destination permissions on first transfer to a new server.

## Pitfalls

- Do not leave timestamped backup files inside directories that use bare glob includes (e.g. `/etc/logrotate.d/*`).
- `/srv/backup` is a rollback staging area, not an archive. It is not assumed covered by the real backup system.
- A restored file with wrong SELinux context looks exactly like a failed rollback. Always `restorecon -v` and `ls -Z`.
- `mysqldump` without `umask 077` creates a world-readable dump file on disk during the write window.

## Verification

- [ ] Authorization confirmed (attributable to operator or deputy)
- [ ] Free space verified and sufficient
- [ ] Backup files created under `/srv/backup/` with correct ownership
- [ ] /srv/backup/ root owned only, stat confirms 0700
- [ ] Service state confirmed after change
- [ ] /CHANGES.md entry written
- [ ] rollback path documented in the escalation handoff
