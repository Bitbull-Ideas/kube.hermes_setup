# Post-Setup Operations

This file is an operator hint for actions that require the installed Hermes runtime. It is copied into the bootstrap data when a profile is composed, but it is **not executed automatically**.

## Configure the log watchdog cron job

The shared `hermes-log-watchdog` skill provides the checkpointed scanner and the recommended LLM analysis prompt. After the first installation, run the following from the Hermes host or the selected profile environment:

```bash
mkdir -p ~/.hermes/scripts
cp ~/.hermes/skills/hermes-log-watchdog/scripts/check_hermes_logs.py ~/.hermes/scripts/check_hermes_logs.py
chmod 700 ~/.hermes/scripts/check_hermes_logs.py
~/.hermes/scripts/check_hermes_logs.py
```

The first run initializes checkpoints at the end of existing log files. It is intentionally silent for historical entries.

Create the LLM-driven cron job only after choosing the delivery channel:

```bash
hermes cron create '0 8,20 * * *'
```

Use these job settings:

- **Name:** `Hermes log watchdog`
- **Script:** `check_hermes_logs.py`
- **LLM agent:** enabled (`no_agent: false`)
- **Delivery:** explicitly select one connected target before creating the job
- **Prompt:** use the analysis prompt from `skills/hermes-log-watchdog/SKILL.md`

## Choose the delivery channel

Do not guess or hard-code a channel. Select the intended destination for this deployment:

- `origin` / WebUI home channel: deliver back to the channel where the cron job is configured;
- Telegram: use the connected Telegram chat or topic target;
- another connected platform: use its explicit channel/chat target;
- local-only testing: use `deliver=local` and inspect the saved cron output.

The exact target depends on how this Hermes instance is connected. Verify it before enabling the recurring job:

```bash
hermes cron list
hermes cron status
```

If using the Hermes API/tooling, set `deliver` explicitly when creating the job. For example, use `origin` for the current WebUI/home channel, or the platform-specific target supplied by the operator. Never invent a private chat ID or silently fan out alerts to all channels.

## Verification checklist

- [ ] `~/.hermes/scripts/check_hermes_logs.py` exists and is executable.
- [ ] The first scanner run created the checkpoint state and did not report old history.
- [ ] The cron job is LLM-driven (`no_agent: false`).
- [ ] The script path is relative: `check_hermes_logs.py`.
- [ ] The delivery target is explicitly chosen and documented for this installation.
- [ ] `hermes cron list` shows the expected schedule and target.
- [ ] A controlled test alert was delivered to the selected channel without exposing secrets.

This post-setup step is intentionally manual because channel selection is deployment-specific and cron jobs cannot ask an operator for clarification when they run unattended.
