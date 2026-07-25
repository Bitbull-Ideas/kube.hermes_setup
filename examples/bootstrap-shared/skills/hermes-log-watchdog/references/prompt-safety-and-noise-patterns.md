# Prompt safety and noise patterns for Hermes log watchdog

Use this when the watchdog itself is blocked by the cron prompt-injection scanner, or when alerts are dominated by benign operational warnings.

## Cron prompt scanner false-positive from raw log content

Symptom:

```text
Cron job 'Hermes log watchdog': assembled prompt blocked by injection scanner — Blocked: prompt matches threat pattern 'sudoers_mod'
```

Root cause:

The watchdog embeds raw warning/error examples in the cron prompt. If a previous session logged security-sensitive administration strings such as `/etc/sudoers`, `/etc/sudoers.d/...`, or `visudo`, the assembled prompt can match Hermes' cron injection scanner. The scanner is behaving correctly; the watchdog output needs to be prompt-safe.

Fix pattern:

Sanitize log excerpts before printing them, instead of broad-ignoreing all security-related warnings. Keep enough context for diagnosis, but redact trigger substrings:

```python
SANITIZE_PATTERNS = [
    (re.compile(r"/etc/sudoers(?:\.d/[^\s'\"`]+)?", re.I), "[redacted-sudoers-path]"),
    (re.compile(r"\bvisudo\b", re.I), "[redacted-visudo]"),
    (re.compile(r"authorized_keys", re.I), "[redacted-authorized-keys]"),
]

def sanitize_for_prompt(line: str) -> str:
    for pattern, repl in SANITIZE_PATTERNS:
        line = pattern.sub(repl, line)
    return line
```

Apply this to both normalized counter labels and example lines before printing.

## Known-actionable patterns to group in reports

- `Cancelled task ... did not exit within 5s`: usually a `/stop` while a tool/agent task is slow to honour cancellation. Report as low-priority unless frequent.
- `Shutdown context: signal=SIGTERM under_systemd=yes`: check nearby gateway log lines. If teardown and restart are clean, classify as planned/systemd restart noise, not a crash.
- Vite `chunkSizeWarningLimit`: web UI build warning, normally non-runtime noise.
- `skill_manage ... Skill '<path-like-name>' not found`: often the agent passed a skill filesystem path instead of the registered skill name. Use `skills_list()`/`skill_view()` and patch the class-level skill or umbrella by registered name.

## Reporting discipline

For each unique pattern, verify with one nearby source when possible: cron job state, gateway status, config, or surrounding log lines. Avoid reporting every duplicated copy from `agent.log`, `errors.log`, and `gateway.log` as separate problems; group by root cause.
