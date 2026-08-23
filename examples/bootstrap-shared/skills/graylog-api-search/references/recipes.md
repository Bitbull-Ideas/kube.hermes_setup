# Graylog query recipes

All examples assume the setup from SKILL.md (`GRAYLOG_URL`,
`GRAYLOG_API_TOKEN` auto-loaded from `.env`). Run `fields --filter
<keyword>` first on each new instance to confirm real field names — field
names below are common for Linux auditd/journald and Windows event log
pipelines, but your instance's parsers may differ.

Adjust `--range` (seconds) to the investigation window: `3600` = 1h,
`86400` = 24h, `604800` = 7d. For a specific incident window use
`--from 2026-08-23T10:00:00.000Z --to 2026-08-23T11:00:00.000Z` instead.

## Security investigation

**Failed SSH logins in the last hour, most recent first:**
```bash
python3 scripts/graylog_query.py search \
  --query 'sshd AND (Failed OR "Authentication failure")' \
  --range 3600 --fields timestamp,source,message --limit 50
```

**Brute-force pattern — count failed auth attempts per source host:**
```bash
python3 scripts/graylog_query.py aggregate \
  --query 'sshd AND (Failed OR "Authentication failure" OR "Invalid user")' \
  --range 3600 --group-field source --metric count --limit 20
```
A single `source` (log-forwarding host) with an unusually high count over a
short `--range` is the classic brute-force signal. Since `gl2_remote_ip`
is the *forwarder's* IP, not the attacker's, pull the actual attacker IP
from `message` text (`addr=`, `from `) via `search`.

**auditd failed logins (structured, cross-platform via PAM):**
```bash
python3 scripts/graylog_query.py search \
  --query 'log_type:auditd AND audit_type:USER_LOGIN AND res=failed' \
  --range 3600 --limit 50
```

**Successful privileged/root logins (audit trail of who got in):**
```bash
python3 scripts/graylog_query.py search \
  --query 'audit_type:USER_LOGIN AND res=success AND acct=\"root\"' \
  --range 86400 --limit 50
```

**Windows: privileged logons + new accounts + security group changes:**
```bash
# 4672 = special privileges assigned, 4624 = successful logon
python3 scripts/graylog_query.py search \
  --query 'winlog_event_id:(4672 OR 4624)' --range 3600 --limit 50

# 4720 = user account created, 4732 = member added to security-enabled group
python3 scripts/graylog_query.py search \
  --query 'winlog_event_id:(4720 OR 4732 OR 4728 OR 4756)' --range 86400 --limit 50

# 1102 = audit log cleared -- classic anti-forensics indicator
python3 scripts/graylog_query.py search \
  --query 'winlog_event_id:1102' --range 604800 --limit 20
```

**Suspicious process execution (auditd EXECVE / SYSCALL execve):**
```bash
python3 scripts/graylog_query.py search \
  --query 'audit_type:EXECVE AND (message:*curl* OR message:*wget* OR message:*base64* OR message:*nc\ -e*)' \
  --range 86400 --limit 50
```

**BPF/eBPF program loads (can indicate rootkits or legitimate monitoring — verify context):**
```bash
python3 scripts/graylog_query.py aggregate \
  --query 'audit_type:BPF' --range 86400 --group-field source --metric count --limit 20
```

**New crypto keys / SSH key material added:**
```bash
python3 scripts/graylog_query.py search \
  --query 'audit_type:CRYPTO_KEY_USER' --range 86400 --limit 30
```

## Audit

**Sudo usage — who ran what, per host, last 24h:**
```bash
python3 scripts/graylog_query.py search \
  --query 'sudo AND COMMAND=' --range 86400 --fields timestamp,source,message --limit 100
```

**Sudo session count per host (spot anomalous admin activity):**
```bash
python3 scripts/graylog_query.py aggregate \
  --query 'sudo' --range 86400 --group-field source --metric count --limit 20
```

**Service start/stop audit (systemd unit changes):**
```bash
python3 scripts/graylog_query.py search \
  --query 'audit_type:(SERVICE_START OR SERVICE_STOP)' --range 86400 --limit 50
```

**Credential acquisition/disposal (who authenticated as another identity via sudo/su/PAM):**
```bash
python3 scripts/graylog_query.py search \
  --query 'audit_type:(CRED_ACQ OR CRED_DISP)' --range 3600 --limit 50
```

**Full audit trail for one host over an incident window (absolute time):**
```bash
python3 scripts/graylog_query.py search \
  --query 'source:HOSTNAME' \
  --from 2026-08-23T10:00:00.000Z --to 2026-08-23T11:00:00.000Z \
  --limit 200
```

**Which log sources/parsers are active (sanity check ingestion coverage):**
```bash
python3 scripts/graylog_query.py aggregate \
  --query '*' --range 3600 --group-field log_type --metric count --limit 10
```

## Error / problem drill-down

**Severity distribution right now (level 0-3 = emerg/alert/crit/err):**
```bash
python3 scripts/graylog_query.py aggregate \
  --query '*' --range 3600 --group-field level --metric count --limit 10
```

**Top hosts generating errors (level <= 3) in the last hour:**
```bash
python3 scripts/graylog_query.py aggregate \
  --query 'level:<=3' --range 3600 --group-field source --metric count --limit 20
```

**Time-bucketed error trend, split by severity — find when a spike started:**
```bash
python3 scripts/graylog_query.py trend \
  --query 'level:<=4' --range 3600 --split-field level
```
Look for a bucket where `count()` jumps sharply vs. neighboring buckets;
that timestamp is your incident start — pivot to `search` with
`--from`/`--to` bracketing it for the raw messages.

**Time-bucketed trend for one specific host (did errors correlate with a deploy/restart?):**
```bash
python3 scripts/graylog_query.py trend \
  --query 'source:HOSTNAME AND level:<=4' --range 86400
```

**Drill into the raw error messages once you have a suspect window:**
```bash
python3 scripts/graylog_query.py search \
  --query 'level:<=3' \
  --from 2026-08-23T20:30:00.000Z --to 2026-08-23T20:45:00.000Z \
  --fields timestamp,source,message --limit 100
```

**Windows service failures / unexpected shutdowns:**
```bash
# 7036 = service entered running/stopped state, 41 = unexpected shutdown
python3 scripts/graylog_query.py search \
  --query 'winlog_event_id:(7036 OR 41 OR 6008)' --range 86400 --limit 50
```

**Average processing latency per host (Graylog pipeline health, not app errors,
but useful to rule out ingestion lag before blaming an app):**
```bash
python3 scripts/graylog_query.py aggregate \
  --query '*' --range 3600 --group-field source \
  --metric avg --metric-field gl2_processing_duration_ms --limit 10
```

## Triaging with `events` / `patterns` / `--count-only`

**Check what Graylog itself already flagged before hand-rolling detection:**
```bash
python3 scripts/graylog_query.py events --range 86400 --alerts-only
```
If this is non-empty, start from those events (they already encode a
condition someone configured as worth alerting on) instead of re-deriving
signal from `aggregate`/`trend`. An empty result with a healthy log volume
usually just means no Event Definitions exist yet on this instance --
verify with `curl .../api/events/definitions` before treating "no events"
as "nothing happened."

**Cheap existence/volume check before committing to a full search:**
```bash
python3 scripts/graylog_query.py search --query 'audit_type:CRYPTO_KEY_USER' \
  --range 604800 --count-only
```
Returns just `total_results` — use this to decide whether a full
`search --limit N` (or an `aggregate`) is even worth running.

**Characterize a noisy stream of log lines into common shapes (poor-man's
Illuminate pattern detection):**
```bash
python3 scripts/graylog_query.py patterns \
  --query 'source:HOSTNAME' --range 3600 --limit 500 --top 15
```
Turns hundreds/thousands of near-duplicate lines (varying only by PID,
timestamp, IP, session id, etc.) into a ranked list of message templates —
skim this first to see *what kinds* of things a host is logging before
reading raw messages one by one. A template with an unexpectedly high
count, or one that doesn't normally appear, is worth a closer `search`.

**Combine `patterns` with a severity filter to characterize an error burst:**
```bash
python3 scripts/graylog_query.py patterns \
  --query 'level:<=4 AND source:HOSTNAME' --range 3600 --limit 500 --top 10
```
