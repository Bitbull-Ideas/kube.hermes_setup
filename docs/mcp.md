# MCP servers for Hermes

This document is the shared reference for MCP (Model Context Protocol) server
configuration in this stack. It gives Hermes users and agents the verified
configuration patterns, setup instructions, and troubleshooting notes for the
MCP servers that are known to work here.

It complements:

- [`docs/security.md`](security.md) — where secrets live and how they are referenced
- [`docs/persistent-software.md`](persistent-software.md) — the managed Node/npm/npx runtime that stdio MCP servers run from
- [`docs/operations.md`](operations.md) — config reload, rollout, and backup rules

## How Hermes loads MCP servers

- Configuration lives under `mcp_servers:` in the **profile's** `config.yaml`
  (`$HERMES_HOME/config.yaml` or `$HERMES_HOME/profiles/<profile>/config.yaml`).
  There is no global default that applies to all profiles — a server configured
  in one profile is invisible to the others.
- A stdio server is described by `command`, `args`, and `env`; an HTTP/SSE
  server by `url` (and optional `headers`).
- `${VAR}` placeholders in `env` values are resolved from the profile's
  secret scope / `.env` (e.g. `GOOGLE_MAPS_API_KEY: ${GOOGLE_MAPS}`). Cursor-style
  `${env:VAR}` also works. Never put the raw API key into `config.yaml` —
  keep it in `.env` or a Kubernetes-backed environment variable and reference
  it by name.
- **Config reload:** editing `config.yaml` does not restart an already running
  MCP process. The profile/gateway must be reloaded (rollout restart on
  Kubernetes, gateway restart on hosts), and afterwards check which package the
  running process actually uses. Testing against a stale, still-running MCP
  connection is not a valid test.
- Hermes resolves a bare `npx`/`npm`/`node` command against the managed Node
  runtime under `$HERMES_HOME/node/bin` even when the server `env.PATH` is
  filtered, and wraps the stdio child in a parent-death watchdog. It does
  **not** inject transport flags for you: whatever `args` you write is what
  the server process receives, verbatim.

### Verifying an MCP server

```bash
hermes mcp list              # configured servers and status
hermes mcp test <name>       # connect + tool discovery; must show "Tools discovered: N"
```

A successful stdio connection reports `✓ Connected` and the tool count.
`✗ Connection failed` with a timeout of roughly `connect_timeout` (default
120 s) usually means the process started but is not speaking MCP over stdin —
see the pitfalls below.

### Manual stdio smoke test (outside Hermes)

Useful to separate "package works" from "Hermes wiring works":

```bash
export PATH="$HERMES_HOME/node/bin:/usr/local/bin:/usr/bin:/bin"
export LD_LIBRARY_PATH="$HERMES_HOME/node/lib"
# for @cablate/mcp-google-map (tested version pinned):
GOOGLE_MAPS_API_KEY="CHANGE_ME" npx -y '@cablate/mcp-google-map@0.0.55' --stdio
```

A valid MCP handshake over stdio is:

1. `initialize` (JSON-RPC 2.0)
2. `notifications/initialized`
3. `tools/list`
4. `tools/call` against one tool

If the process prints startup banners and then goes quiet while your
`initialize` is unanswered, it is running in the wrong transport mode.

## Google Maps MCP (`google-maps`)

Verified working in the QA namespace of this stack (k3s, single node;
Hermes Agent v0.20.3, managed Node v26.x). Package: `@cablate/mcp-google-map`
(tested at `0.0.55`). Transport: stdio via `npx`.

Provides 18 tools: `maps_geocode`, `maps_reverse_geocode`, `maps_search_places`,
`maps_search_nearby`, `maps_place_details`, `maps_directions`,
`maps_distance_matrix`, `maps_elevation`, `maps_timezone`, `maps_weather`,
`maps_air_quality`, `maps_static_map`, `maps_batch_geocode`,
`maps_explore_area`, `maps_plan_route`, `maps_compare_places`,
`maps_search_along_route`, `maps_local_rank_tracker`.

### Why this package

The originally used `google-maps-mcp-server` set `routingPreference:
TRAFFIC_AWARE` on every route request. Google only allows `routingPreference`
for `DRIVE` and `TWO_WHEELER` — not `TRANSIT` — so transit (ÖV) queries failed
with:

```text
Routing preference cannot be set for TRANSIT travel mode
```

`@cablate/mcp-google-map` applies that option only to car trips and works for
transit routes. Verified on QA: `maps_directions` with `mode: "transit"`
returned a complete train/bus connection, and `mode: "driving"` returned the
expected distance/duration.

### Secret

Store the key in the profile's `.env` (or a Kubernetes-backed env var for
pod deployments) under a private name; do not commit it:

```dotenv
GOOGLE_MAPS=CHANGE_ME
```

The MCP server itself expects `GOOGLE_MAPS_API_KEY`; the block below maps the
two. For a manual test outside Hermes, export the mapping explicitly:

```bash
export GOOGLE_MAPS_API_KEY="$GOOGLE_MAPS"
```

### Config entry (verified)

Add a `google-maps` entry under the profile's **existing** `mcp_servers`
mapping. Do not append a second top-level `mcp_servers:` key — duplicate
top-level keys are rejected by strict YAML loaders and, with lenient loaders,
the later block silently replaces the earlier one, discarding any already
configured servers. Add the full block only if the profile has no
`mcp_servers` key at all:

```yaml
mcp_servers:
  google-maps:
    command: npx
    args:
      - -y
      - '@cablate/mcp-google-map@0.0.55'
      - --stdio
    env:
      GOOGLE_MAPS_API_KEY: ${GOOGLE_MAPS}
      PATH: /opt/data/node/bin:/opt/data/.local/bin:/usr/local/bin:/usr/bin:/bin
      LD_LIBRARY_PATH: /opt/data/node/lib
    connect_timeout: 120.0
    enabled: true
```

The package spec is **pinned to the tested version** `0.0.55`. An unpinned
spec (`@cablate/mcp-google-map`) makes `npx` resolve the current npm dist-tag,
so a newer release — or any machine with a different npm cache — can run
different code than what was verified. Re-verify with `hermes mcp test`
before updating the pin.

Then reload/rollout the agent so the running process picks up the change:

```bash
# Kubernetes (this stack)
kubectl -n <namespace> rollout restart deploy/hermes-agent
kubectl -n <namespace> rollout status deploy/hermes-agent --timeout=240s
```

### Pitfalls (all reproduced on QA, 2026-08-30)

1. **`--stdio` is mandatory and belongs after the package name.** Without it
   the package starts an HTTP server on `0.0.0.0:3000` and ignores stdin, so
   Hermes' stdio client times out (`✗ Connection failed (123099ms)`).
   Hermes does not add the flag automatically.
2. **Argument order matters through `npx`.** `-y` and the package name come
   first; only *package* flags (like `--stdio`) go after the package name.
   `npx --stdio -y @cablate/mcp-google-map` makes npm treat `--stdio` as an
   npm flag and the server again runs in HTTP mode — same timeout symptom,
   and the running process shows `npm exec @cablate/mcp-google-map` with no
   `--stdio` in its argv.
3. **Wrong profile.** The relevant file is the profile's `config.yaml`, not
   another profile's or the default config.
4. **Stale server process.** After a config change, the running process must
   match the new config. A process showing `npx -y google-maps-mcp-server`
   (old package) or `npm exec @cablate/mcp-google-map` (missing `--stdio`)
   means the reload did not happen or the flag was not propagated.
   The expected pinned form is `npm exec @cablate/mcp-google-map@0.0.55 --stdio`.
5. **Transit times are live data.** Do not reuse departure times from a
   previous answer; re-run `maps_directions` with `mode: "transit"` for each
   new trip.

### Verification result on QA

- `hermes mcp test google-maps` → `✓ Connected`, `✓ Tools discovered: 18`
- Process tree: `npx -y @cablate/mcp-google-map@0.0.55 --stdio` →
  `node .../mcp-google-map --stdio`
- Manual stdio smoke test: `initialize` / `tools/list` /
  `tools/call maps_geocode ("Flawil, Switzerland")` all succeeded
- `maps_directions` transit and driving modes return `success: true`

### Google documentation

- Routes API `computeRoutes`:
  <https://developers.google.com/maps/documentation/routes/reference/rest/v2/TopLevel/computeRoutes>
- Transit routes:
  <https://developers.google.com/maps/documentation/routes/transit-route>
- Package: <https://github.com/cablate/mcp-google-map>

## Adding another MCP server

Keep entries in this document for every server that is verified in this stack:

- name as used in `mcp_servers`, package/endpoint and tested version
- transport (stdio/HTTP/SSE) and the exact config block
- secret name and where it is stored
- known pitfalls
- last-verified date and verification evidence (tool count, key commands)

Unverified server configs should not be treated as instructions; verify with
`hermes mcp test` first and then document the result here.
