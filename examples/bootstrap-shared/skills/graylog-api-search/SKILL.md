---
name: graylog-api-search
description: "Use when searching Graylog logs for security investigation, audit, or error triage via REST API without a native Graylog MCP connector. Runs the Views Search REST API to search/aggregate/trend/cluster messages and check triggered alerts, mirroring Graylog 7.1's search_messages / aggregate_messages / list_fields MCP tools plus extras cherry-picked from other log-management MCP servers."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [graylog, logs, security, audit, siem, rest-api, incident-response]
    related_skills: []
---

# Graylog API Search

Query a Graylog instance's REST API directly with a personal API token — no
native Graylog MCP connector required. Implements the same three
"Search and Aggregation" capabilities Graylog's own MCP integration exposes
(https://go2docs.graylog.org/current/setting_up_graylog/model_context_protocol__mcp__tools.htm),
plus extras cherry-picked from other log-management MCP servers, using the
public Views Search REST API that backs the Graylog web UI.

## When to use this

- The user asks you to search Graylog logs, find security events, audit
  logins/sudo/config changes, or drill into error spikes, and no native
  Graylog MCP server is configured in this session.
- You have (or can find) a `GRAYLOG_API_TOKEN` — check `.env` files
  (commonly `/opt/data/.env` under `HERMES_HOME` in this environment) for
  `GRAYLOG_*` vars before asking the user.

This is read-only investigation. Nothing here writes to a managed target;
treat findings as evidence for the standard investigate-first workflow, not
as authorization to change anything.

## Setup

The script auto-loads its credentials from `/opt/data/.env` (override the
path with `GRAYLOG_ENV_FILE`) — **no manual `source`/`export` needed** if
that file already has these three vars:

```bash
GRAYLOG_API_TOKEN=<personal API token>
GRAYLOG_URL='https://<graylog-host>'          # no trailing slash, no /api
GRAYLOG_URL_SSL_VERIFY=False                  # only set for self-signed/lab certs
```

Auth model (per Graylog's REST API Access Tokens doc,
https://go2docs.graylog.org/current/setting_up_graylog/rest_api_access_tokens.htm):
the token is used as the HTTP Basic **username**, with the literal string
`token` as the password. `GRAYLOG_URL_SSL_VERIFY` defaults to verifying
(True) if unset or set to anything other than `False`/`0`/`no`/`off` —
only disable it for known self-signed lab instances.

**If any of the three vars are missing**, guide the user to add them to
`/opt/data/.env` (or wherever the profile's env file lives) rather than
hardcoding a token in a command or in this skill. To get a token: Graylog
web UI → user menu → **Edit tokens** (or **System > Users and Teams >
Tokens**) → create a token → paste its value as `GRAYLOG_API_TOKEN`. Do
not print/echo the raw token value back to the user once entered.

Run once to confirm access:
```bash
python3 scripts/graylog_query.py fields --filter source   # sanity check
```
If it exits with "GRAYLOG_URL / GRAYLOG_API_TOKEN not set..." the vars
aren't in `.env` yet (or `GRAYLOG_ENV_FILE` points elsewhere) — that error
message itself tells the user exactly what to add.

Requires the `requests` Python package. Install it via the Hermes addon
venv (add `requests` to the profile's `requirements.txt`) or `pip install
requests` in the runtime addon environment.

## Tools (script subcommands)

Script: `scripts/graylog_query.py`.

| MCP tool equivalent | Subcommand | REST path(s) |
|---|---|---|
| `list_fields` | `fields [--filter STR]` | `GET /api/views/fields` |
| `search_messages` | `search --query Q [--range S \| --from --to] [--fields F,F] [--limit N] [--offset N] [--count-only]` | `POST /api/views/search` → `POST .../execute` → poll `GET /api/views/search/status/{job_id}` |
| `aggregate_messages` | `aggregate --query Q --group-field F [--metric count\|avg\|min\|max\|sum\|card\|stddev\|percentile] [--metric-field F] [--percentile N] [--range S] [--limit N]` | same 3-step flow, `search_type: pivot` |
| (extra) time-series drill-down | `trend --query Q [--range S] [--split-field F]` | same flow, `pivot` with a `time` row group (1-min/auto buckets), optional column split |
| (extra) triggered alerts | `events --range S [--query Q] [--alerts-only] [--page N] [--limit N]` | `POST /api/events/search` |
| (extra) message-pattern clustering | `patterns --query Q [--range S] [--limit N] [--top N]` | fetches N messages via `search`, normalizes numbers/IPs/UUIDs/hex client-side, ranks by frequency |

By default all subcommands search across **all streams** (no `--stream`
filter). Only pass `--stream ID1,ID2` if the user explicitly asks to scope
to specific streams; resolve stream titles→IDs via `GET /api/streams`
(there's no dedicated subcommand for this — it's rarely needed).

All commands print JSON to stdout. `search`/`aggregate`/`trend`/`patterns`
follow the Views API's async create→execute→poll pattern — the script
handles this for you (create search definition, execute, poll `status`
until `execution.done`, default 30s timeout).

Query strings are Lucene syntax (Graylog's native query language), e.g.
`sshd AND (Failed OR "Authentication failure")`, `source:win-host01`,
`level:<=3`, `NOT source:app01.example.com`.

### Why these extra subcommands exist

Cherry-picked from other log-management MCP servers' feature sets after
comparing what they offer beyond plain search/aggregate (Elastic's
Elasticsearch MCP server, Grafana's mcp-grafana with Loki tools, AWS's
CloudWatch Logs MCP server, and the community Datadog MCP server):

- **`events`** — every one of those servers has a dedicated
  alerts/incidents-style tool (CloudWatch `get_active_alarms`, Datadog
  `get-incidents`, Grafana OnCall alert-group tools). Graylog has its own
  Events/Alerts subsystem (`/api/events/search`) that's independent of raw
  message search — querying it first tells you what Graylog *already
  flagged* before you re-derive the same signal by hand with `aggregate`/
  `trend`. Cheap and worth checking early in any investigation.
- **`patterns`** — CloudWatch's `analyze_log_group` and Grafana's "Query
  Loki patterns" both do server-side log-pattern/anomaly detection to turn
  thousands of raw lines into a handful of templates. Graylog's equivalent
  (Illuminate) is an enterprise feature not always available, so
  `patterns` reimplements the core idea client-side: sample N messages,
  normalize out numbers/IPs/UUIDs/hex, count how many collapse into each
  template. Turns "3600 sshd lines" into "8 distinct message shapes,
  ranked by frequency" — much faster to eyeball for anomalies than paging
  through raw `search` output.
- **`--count-only` on `search`** — mirrors the "just tell me if this
  matches anything, cheaply" pattern used for existence/volume checks
  (e.g. CloudWatch's metric-only queries, Datadog's log counts without
  fetching bodies). Sets `limit:1` server-side and skips returning message
  bodies in the script's output, so you get `total_results` fast without
  pulling data you don't need — useful before committing to a full
  `search --limit 200`.
- **Considered and deliberately NOT added**: dashboard/panel management
  (Grafana), metric namespaces/alarm-recommendation tools (CloudWatch),
  custom ES|QL/search-template config tools (Elastic) — those are
  configuration/write operations or domains (metrics, dashboards) outside
  this skill's read-only log-search scope. `--stream` scoping already
  covers Graylog's equivalent of "pick a datasource/index".

## Field discovery first

Field names vary a lot by log source/pipeline. Before writing a query or
aggregation, run `fields --filter <keyword>` to confirm the real field name
and type (`enumerable`, numeric type, etc.) rather than guessing. Fields
commonly seen in Linux/Windows log pipelines (confirm per-instance, don't
assume they exist):

- `source` — originating hostname (best field for "top talkers" / per-host counts)
- `level` — syslog severity number (0=emerg .. 7=debug; `3`=err, `4`=warning, `6`=info)
- `log_type` / `fb_tag` — parser/pipeline tag, e.g. `auditd`, `journald`, `security_file`
- `audit_type` — Linux auditd record type: `USER_LOGIN`, `USER_ACCT`, `EXECVE`,
  `SYSCALL`, `SERVICE_START`/`SERVICE_STOP`, `CRED_ACQ`/`CRED_DISP`, `BPF`, etc.
- `gl2_remote_ip` — IP of the log-forwarding agent (NOT the attacker's IP —
  that's usually still embedded in `message` text for sshd/auditd lines,
  e.g. `addr=203.0.113.7`)
- `winlog_event_id` — Windows Event ID (4624=logon, 4672=privileged logon,
  1102=audit log cleared, 4720=user created, 4732=added to security group...)
- `timestamp` — always present, ISO-8601

If no GeoIP or dedicated `source_ip`/`user` enrichment fields exist on a
given instance, IPs/usernames for auth events live inside the raw `message`
text — use Lucene substring/phrase queries (`message:*Failed*`) or auditd's
`msg` sub-fields as the practical fallback until/unless extractors are
added.

## Recipes

See `references/recipes.md` for ready-to-run query recipes grouped by:
- **Security investigation** (failed/successful auth, privilege escalation,
  new accounts, suspicious process execution, brute-force patterns)
- **Audit** (sudo usage, service start/stop, config/account changes, admin
  logon tracking)
- **Error/problem drill-down** (severity trends over time, top error
  sources, spike detection with `trend`, correlating a host's errors to a
  time window)
- **Triaging with `events`/`patterns`/`--count-only`** (check what Graylog
  already flagged, characterize noisy log streams, cheap existence checks)

Each recipe gives the exact subcommand + flags; adjust `--range` (seconds)
and field names to the target instance after running `fields` first.

## Pitfalls

- **CSRF header required.** Every POST (`views/search`, `.../execute`) needs
  `X-Requested-By: <anything>` or Graylog returns 400 `"CSRF protection
  header is missing"`. The script sets this by default — if you call the
  API directly with curl, don't forget it.
- **Search execution is async.** `POST .../execute` returns immediately with
  a job id and often `execution.done: false`. You must poll
  `GET /api/views/search/status/{job_id}` until `done: true` — polling the
  wrong URL shape (e.g. `/views/search/{id}/execute/{jobId}`) 404s. The
  script's `run_search()` handles this; reuse it rather than re-deriving.
- **Legacy `/api/search/universal/relative` returns 403 "Not authorized"**
  even with a valid token on Graylog 7.1 — use the Views Search API
  (`/api/views/search`) instead, which is what the web UI and the native
  MCP tools use.
- **No native `/api/mcp` REST proxy is guaranteed to exist.** Graylog's MCP
  support is a first-class protocol endpoint requiring `System >
  Configurations > MCP` to be toggled on plus a compatible MCP client — it
  is not just another REST path, and may be unavailable or disabled. This
  skill's REST-based approach works regardless of whether that toggle is
  enabled, since it rides the same permission model as any other API token.
- **`--metric-field` needs a genuinely numeric field.** `fields` reports a
  field's `type.type` — only `long`/`double`/`int`/`float` work with
  avg/sum/min/max/stddev/percentile; using an enumerable string field
  fails silently or returns nonsense.
- **Empty-string / `(Empty Value)` buckets are common** in aggregations —
  many messages don't populate every field (e.g. `level` is absent on
  journald-only lines). Don't treat that bucket as an anomaly by default.
- **Self-signed cert**: controlled by `GRAYLOG_URL_SSL_VERIFY` in `.env`
  (defaults to verifying). Set it to `False` only for known self-signed/lab
  instances — do not disable verification against a hardened/production
  Graylog without the user's explicit say-so.
- **Never hardcode the token in a command line or in this skill.** Always
  read it from `.env` via the script's auto-load; if asked to add it,
  write it to the `.env` file, not into a shell history or a script arg.
- **`events` returning empty is often correct, not broken.** It only
  returns instances of configured Event Definitions (alert rules) firing —
  if the instance has none configured (`GET /api/events/definitions` is
  empty), `events` will always return `total_events: 0` regardless of how
  much raw log volume exists. Check event definitions exist before trusting
  an empty result as "nothing happened."
- **`patterns` is a sampling heuristic, not exhaustive.** It clusters
  whatever `--limit` messages the query returns (default 10 — raise it,
  e.g. `--limit 500`, for meaningful clustering); a low-frequency but
  important message won't surface if it wasn't in the sample. Use
  `aggregate`/`trend` first to confirm you're looking at the right time
  window and query, then `patterns` to characterize what's in it.

## Verification performed

All subcommands (`fields`, `search`, `aggregate`, `trend`, `events`,
`patterns`, `--count-only`) were exercised live against a Graylog 7.1.7
instance using a token from `.env`, confirming real result payloads
(message counts, per-host aggregates, auditd/sshd/sudo events, a
level-split time trend, an empty-but-correct events query with no alert
rules configured, and multi-way pattern clusters from sampled sudo/auditd
messages) before this skill was written.
