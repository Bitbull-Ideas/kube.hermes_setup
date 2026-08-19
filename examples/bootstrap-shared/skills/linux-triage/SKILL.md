---
name: linux-triage
description: "Use when diagnosing a failing or misbehaving Linux system to reconstruct what changed before the problem started — subsystem state, package history, log timeline, and environmental deltas."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [linux, triage, diagnostics, troubleshooting, incident-response]
    related_skills: [linux-change-safety, ansible-fleet-change]
    related_skill_classifications:
      linux-change-safety: bundled
      ansible-fleet-change: bundled
---

# Linux Triage

## Trigger

An alert, user report, or dashboard shows a system in a degraded or failing state. Before any change, reconstruct what changed and when.

## Workflow

1. **Establish the incident timeline.** When did the problem first appear? What was the last known-good state? Check alert timestamps, monitoring graphs, and user reports.

2. **Detect OS family** (never assume):
   ```bash
   source /etc/os-release && echo "$ID $VERSION_ID"
   ```
   Branch all subsequent commands accordingly.

3. **Check for recent changes — package level:**

   RHEL-family:
   ```bash
   # Most recent N transactions
   dnf history list | head -20
   dnf history info <transaction-id>
   # All packages installed/updated in reverse chronological order
   rpm -qa --last | head -30
   ```

   Debian-family:
   ```bash
   # Full package history
   grep -E 'install|upgrade|remove|purge|dist-upgrade' /var/log/apt/history.log | tail -50
   # Package install/update timestamps
   zgrep ' install ' /var/log/dpkg.log* | tail -20
   ```

4. **Check for disk, memory, and resource pressure:**
   ```bash
   df -h
   df -i   # inode exhaustion
   free -h
   dmesg | tail -30
   ```

5. **Check service state and systemd journal:**
   ```bash
   systemctl list-units --state=failed
   journalctl -u <suspected-service> --since "24 hours ago" --no-pager | tail -80
   journalctl -p err --since "24 hours ago" --no-pager | tail -40
   ```

6. **Check logs relevant to the symptom:**

   RHEL-family: `/var/log/secure`, `/var/log/messages`, `/var/log/httpd/` etc.
   Debian-family: `/var/log/auth.log`, `/var/log/syslog`, `/var/log/apache2/` etc.

   ```bash
   journalctl -xe --no-pager | tail -60
   ```

7. **Check network and connectivity:**
   ```bash
   ss -tlnp
   ss -ulnp
   ping -c 3 <critical-dependency>
   nc -zv <host> <port>
   ```

8. **Check SELinux or AppArmor context:**
   ```bash
   # RHEL-family
   getenforce
   ausearch -m avc -ts recent | tail -20
   sealert -l "*" | tail -40
   # Debian-family
   aa-status
   cat /sys/kernel/security/apparmor/profiles
   ```

9. **Correlate.** Map each finding to the incident timeline. What changed, when, and does it explain the symptom? If not, keep looking — check cron jobs, user logins, config file timestamps, and external dependencies.

10. **Document findings** in a structured form:
    - Timeline
    - Trigger event
    - What changed
    - Current system state
    - Root cause hypothesis + confidence level
    - What was *not* checked and why
    - Proposed next step (investigation deeper or solution plan)

## Pitfalls

- Do not run `dnf update` or `apt upgrade` as part of investigation — that's a change, not a diagnosis.
- `df -h` over SSH may show the agent's container filesystem, not the target. Verify with `hostname` and mount inspection.
- A single suspicious log line is not a root cause. Look for the event that *preceded* the symptom.
- Reboot time indicates a kernel update or power event that may have changed system behavior.

## Verification

- [ ] OS family detected correctly
- [ ] Package history reviewed within the incident window
- [ ] Disk, memory, and systemd journal checked
- [ ] SELinux/AppArmor alerts reviewed
- [ ] Timeline reconstructed and root cause hypothesis documented
- [ ] Evidence trail saved to disk (Hermes session compression will discard it)
