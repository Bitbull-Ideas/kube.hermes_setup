# MCP HTTP log patterns from Hermes watchdog runs

Use this reference when the log watchdog reports repeated `tools.mcp_tool` warnings for HTTP/StreamableHTTP MCP servers.

## Pattern: repeated HTTP 400 during initial connection

Typical logs:

```text
MCP server '<name>' initial connection failed (attempt 1/3), retrying in 1s: unhandled errors in a TaskGroup (1 sub-exception)
MCP server '<name>' failed initial connection after 3 attempts, giving up: unhandled errors in a TaskGroup (1 sub-exception)
Failed to connect to MCP server '<name>': Client error '400 Bad Request' for url 'https://.../mcp'
```

High-value checks:

1. Inspect `~/.hermes/config.yaml` for the server under `mcp_servers`:
   - `url`
   - `headers`
   - `ssl_verify`
   - explicit `MCP-Protocol-Version` or `mcp-protocol-version`
2. Verify the active Hermes venv has HTTP MCP support:
   ```bash
   ~/.hermes/hermes-agent/venv/bin/python - <<'PY'
   import importlib.util
   for m in ['mcp', 'mcp.client.streamable_http']:
       print(m, bool(importlib.util.find_spec(m)))
   PY
   ```
3. Probe the endpoint with the same venv and configured auth, but avoid printing secrets. A successful manual initialize with a specific protocol version can prove auth/TLS/endpoint are fine while the Hermes client is sending a version the server rejects.

## Graylog 7.1.x MCP quirk

Observed with Graylog `7.1.3+c34604d` at `/api/mcp`:

- Server supports MCP protocol `2025-06-18`.
- Newer Hermes/MCP SDK may default to `2025-11-25`.
- The server returns HTTP 400 for unsupported `MCP-Protocol-Version` headers, which appears in Hermes logs as a generic TaskGroup failure.
- A direct initialize request using `MCP-Protocol-Version: 2025-06-18` can succeed and list tools, proving this is protocol negotiation/config compatibility rather than bad credentials.

Concrete fix to propose:

```yaml
mcp_servers:
  graylog:
    headers:
      MCP-Protocol-Version: "2025-06-18"
```

Then reload MCP or restart the gateway. If that still fails, reproduce with a minimal `httpx.AsyncClient` + `streamable_http_client` probe and include request/response status plus redacted headers in the report.

## Pattern: `mcp.client.streamable_http is not available`

This means the running Hermes process cannot import HTTP transport support from the MCP Python package. Check the Hermes venv, not system Python:

```bash
~/.hermes/hermes-agent/venv/bin/python - <<'PY'
import importlib.util
print(importlib.util.find_spec('mcp.client.streamable_http'))
PY
```

Fix: upgrade/install `mcp` in the Hermes venv, then restart the process that loads MCP tools. Do not conclude permanently that HTTP MCP is unavailable if the venv later shows the module is present; it may have been fixed but the running gateway still needs a restart.

---

## Pattern: HTTP 400 / Invalid Credentials — Keepalive Cascade Flood

The highest-volume pattern — each failed keepalive attempt generates 4 log entries:

```text
WARNING tools.mcp_tool: MCP server 'graylog' keepalive failed, triggering reconnect:
ERROR mcp.client.streamable_http: Error parsing JSON response
Traceback (most recent call last):  ← JSONRPCError
JSONRPCError.error
```

At 1 attempt per ~20s, this fills the log with hundreds to thousands of entries per day.

### Root Cause

The MCP server rejects the configured credentials and returns **HTTP 400** (or 401) with an empty, non-JSON body or an error message like:

```json
{"type":"ApiError","message":"Invalid credentials in Authorization header"}
```

The Hermes MCP client expects a JSON-RPC response (or streamable-http content). When it gets a 400 with non-JSON body, the `streamable_http` transport fails to parse it and raises an `Error parsing JSON response`. This in turn triggers the keepalive-warning + reconnect cycle.

### Debugging Steps

1. **Probe the MCP endpoint directly** — this tells you whether the server itself is reachable:

   ```bash
   curl -sk -D- --max-time 10 "https://graylog1.bitbull.ch/api/mcp"
   ```

   - `HTTP 200` with `content-type: text/event-stream` → server is healthy, problem is auth
   - `HTTP 401` without body → no auth header sent
   - `HTTP 400` with `"Invalid credentials"` → auth header IS sent, but credentials are wrong
   - Empty `content-length: 0` or no `content-type` header → explains the JSON parse error

2. **Extract and decode the Base64 credentials** from `config.yaml`:

   ```bash
   grep "Authorization:" ~/.hermes/config.yaml | head -1
   # Example: Authorization: Basic Mzg0Y2RjbHJsYzRmbmE...=
   
   # Decode the base64 part (after "Basic ")
   echo "Mzg0Y2RjbHJsYzRmbmE...=" | base64 -d
   ```

3. **Verify credential format** — for Graylog API tokens the decoded string must be:

   ```
   <token_id>:token
   ```

   where `token_id` is a long random hex string. Any other format (e.g. `user:password`) will be rejected.

4. **Test with the extracted credentials** to confirm what the server actually sees:

   ```bash
   AUTH="Basic $(echo -n 'token_id:token' | base64)"
   curl -sk -H "Authorization: $AUTH" \
        -H "Accept: application/json, text/event-stream" \
        -D- --max-time 10 \
        "https://graylog1.bitbull.ch/api/mcp" 2>&1
   ```

   Expected success: `HTTP 200` + SSE-style body (`event: initialized`, `event: tool_list_changed`, etc.).

### Resolution

1. **Generate a new Graylog API token** from the Graylog web UI:
   - System → Users → Edit your user → Tokens → Create new token
   - Copy the generated token string

2. **Encode and update the config:**

   ```bash
   NEW_TOKEN_ID="<token_id_from_graylog>"
   NEW_CREDENTIALS=$(echo -n "${NEW_TOKEN_ID}:token" | base64)
   
   # Write to config.yaml via hermes config (NEVER patch config.yaml directly)
   # Currently there is no direct CLI setter for MCP server headers.
   # Edit the header value in ~/.hermes/config.yaml under mcp_servers.graylog.headers.Authorization:
   #   Authorization: Basic <base64>
   ```

3. **Reload MCP servers:**

   ```bash
   systemctl --user restart hermes-gateway
   ```

   Or, if running without systemd: `/hermes gateway reload` on the gateway CLI.

4. **Verify the fix** by checking logs after restart:

   ```bash
   grep "graylog" ~/.hermes/logs/errors.log | tail -5
   # Should show no new keepalive/JSONRPCError entries for the server.
   ```

### Why This Creates So Many Log Entries

Each failed keepalive is *four* lines of logs (WARNING + ERROR + Traceback + JSONRPCError). If a check runs every ~20–30 seconds, that's ~4 × ~3 = 12 log entries per minute, or ~17,000 per day. Until the credentials are fixed, the flood is relentless — there is no built-in backoff or noise suppression for an MCP server that is configured but permanently failing auth.

### Pitfalls

- **Don't confuse this with the protocol-version mismatch** (documented separately above). Protocol-version errors also produce HTTP 400 but the body is a proper JSON-RPC error, not an auth rejection. Always check the response body.
- **Graylog's `/api/mcp` endpoint requires an API token**, not a password. Using `admin:password` as Basic auth credentials produces the same "Invalid credentials" error.
- **Config reassembly is fragile.** If you decode a stale config, update the token, and re-encode, ensure the new header value is a single line with no trailing whitespace in `config.yaml`.
- **The Graylog API token from the UI is only shown once.** Save it immediately in a password manager or env var before closing the dialog.
