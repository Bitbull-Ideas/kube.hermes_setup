# Authelia + FreeIPA SSO for Hermes — Overview

This document describes the architecture, authentication modes, ownership boundaries, maintenance, upgrade, backup, and security model for protecting Hermes Dashboard and WebUI with Authelia and FreeIPA.

For the executable procedure, see [`authelia-freeipa-sso-setup-guide.md`](authelia-freeipa-sso-setup-guide.md).

**Implementation status:** the current repository implements `local-password` and the native `external-oidc` application wiring. It does not install or manage an installation-specific Authelia/FreeIPA deployment. The `disabled` and `external-proxy` modes remain documentation-only and fail closed when selected.

It is an integration guide. The current `kube.hermes_setup` installer manages Hermes resources; it does not yet fully manage an installation-specific Authelia/FreeIPA deployment.

## Recommended architecture

For **native OIDC**, Authelia is not inline on every Hermes request. The browser starts at Hermes, is redirected to Authelia, authenticates against FreeIPA, and returns to the application's callback. Hermes then validates the OIDC result and creates its own application session:

```text
Browser -> Hermes Dashboard/WebUI
             -> redirect to Authelia OIDC
             -> FreeIPA authentication / OTP policy
             -> OIDC callback to Hermes
             -> Hermes application session
```

For **forward-auth/trusted-proxy** mode, the proxy is inline on each protected request:

```text
Browser -> OPNsense / Traefik / forward-auth proxy
             -> Authelia authorization check
             -> Hermes Dashboard/WebUI
```

Do not combine these diagrams: native OIDC and forward-auth have different bypass, logout, WebSocket, and network-control requirements.

Component ownership:

```text
kube.hermes_setup -> Hermes workloads, PVCs, Services, Ingresses, Hermes Secrets
Authelia          -> authentication portal, OIDC clients, sessions, consent, OIDC keys
FreeIPA           -> users, groups, passwords, existing OTP policy
OPNsense          -> public DNS, edge routing, and TLS policy
```

FreeIPA OTP compatibility is a hard gate: FreeIPA can enforce OTP for LDAP binds through its OTP bind control or global `EnforceLDAPOTP` behavior. Authelia's normal LDAP bind path must be verified to send the required control/credential format; a simple bind with a concatenated password+OTP is not evidence that the FreeIPA OTP control is being used. If Authelia cannot produce the required FreeIPA LDAP OTP bind, this architecture must not be treated as preserving the existing FreeIPA token.


Authelia's LDAP provider first resolves the user's DN with its configured LDAP account, then creates a separate client for a live user bind using the submitted password value. The user credential is not the service-account credential and is not used for later group searches.[8][10]

## Authentication modes

Do not describe retaining a Hermes local password as “triple factor.” If OIDC and the local password are alternatives, it is an MFA bypass. If they are sequential, the extra password is another knowledge factor and adds operational complexity rather than a phishing-resistant factor. The target is one authoritative, MFA-enforced path with no weaker alternative.


| Mode | Dashboard | WebUI | Status/recommendation |
|---|---|---|---|
| `local-password` | Hermes BasicAuth | Hermes password | Current behavior; backward-compatible default |
| `external-oidc` | Hermes self-hosted OIDC | WebUI native OIDC | Recommended target for Authelia/FreeIPA |
| `disabled` | No local app auth | No local app auth | Private/loopback/lab only; fail closed for public exposure |
| `external-proxy` | Trusted proxy design | Trusted proxy design | Documentation-only until header and WebSocket tests are complete |

### `local-password`

Current behavior uses `secret/hermes-dashboard-auth`:

```text
Dashboard: username + password keys
WebUI:     password key
```

It provides one shared local password, not MFA, LDAP, SSO, per-user identity, or TOTP. Keep this mode for backward compatibility or trusted-network bootstrap.

Existing password rotation and backup procedures remain authoritative:

```bash
./maintain.sh rotate-passwords --prompt
./maintain.sh rotate-passwords --generate
./maintain.sh backup ./backups/hermes-YYYYmmddTHHMMSSZ.age
```

### `external-oidc`

This mode must make the external provider the only Dashboard/WebUI login path. The installer must omit:

```text
HERMES_DASHBOARD_BASIC_AUTH_USERNAME
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
HERMES_WEBUI_PASSWORD
```

It must configure separate clients and exact callbacks, validate issuer/client/callback/allow-list settings, and preserve unrelated API-server, Browserless, and runtime Secrets.

The expected flow is:

```text
OIDC authorization-code + PKCE
  -> external IdP authentication/MFA
  -> exact callback
  -> issuer/audience/JWKS/nonce validation
  -> explicit user/group allow-list
  -> Hermes application session
```

Hermes Dashboard documents self-hosted OIDC. WebUI's native OIDC implementation requires an issuer, client ID, callback configuration, and explicit allow claim/values.[5][6]

### Session lifetime policy

The repository defaults define two different controls:

```dotenv
HERMES_AUTH_SESSION_MAX_TTL_SECONDS=43200
HERMES_AUTH_SESSION_IDLE_TTL_SECONDS=7200
```

| Layer | Idle timeout | Absolute maximum | Enforcement |
|---|---:|---:|---|
| Authelia SSO cookie | 2h | 12h | External Authelia configuration; `remember_me` disabled |
| Hermes WebUI application cookie | Not supported | 12h | Installer maps maximum to `HERMES_WEBUI_SESSION_TTL` |
| Hermes Dashboard OIDC session | Not supported | 12h | External Authelia client ID-token lifespan |

The maximum variable is one shared policy value, but this installer directly
controls only WebUI. Operators must apply the same duration to the separately
managed Authelia cookie expiration and Dashboard OIDC-client lifespan. The idle
variable applies only to Authelia because current WebUI and Dashboard sessions
do not extend a sliding expiry based on activity.

When an application session expires while the Authelia SSO cookie remains
valid, an OIDC redirect may silently issue a new application session without a
credential prompt. A credential prompt is expected after Authelia reaches its
two-hour inactivity timeout or 12-hour absolute maximum.

### `disabled`

This is not SSO. It should be accepted only when exposure is explicitly private:

```dotenv
HERMES_AUTH_MODE=disabled
HERMES_PUBLIC_EXPOSURE=private
```

The installer must reject this mode when a public Dashboard/WebUI Ingress, public LoadBalancer/NodePort, or internet-facing hostname is configured. Incomplete OIDC configuration must fail; it must never silently downgrade to `disabled`.

### `external-proxy`

This mode delegates authentication to a proxy/forward-auth gateway:

```text
Browser -> OPNsense/Traefik + Authelia forward-auth -> Hermes
```

The proxy must authenticate and enforce MFA, strip client-supplied identity headers, set its own headers, be the only network path to Hermes, support WebSockets, and provide tested logout. The application must verify the source network before trusting a header. A header name without a trusted-source restriction is unsafe.

Keep this mode documentation-only until tests cover header spoofing, invalid/valid proxy authentication, group authorization, WebSockets, logout, and direct-Service/alternate-Ingress bypass.

## Current repository behavior

The current installer now renders the native `external-oidc` application wiring and omits the local Dashboard/WebUI password references in that mode. It still does not install or manage Authelia/FreeIPA, and a manual live Deployment patch is not durable. The source-of-truth `hermes.env` plus repository template must be used and rerun.
```dotenv
HERMES_AUTH_MODE=local-password
```

Implemented in this repository:

- separate Dashboard/WebUI OIDC issuer, client, scope, public/callback, and WebUI allow-list settings;
- mutually exclusive local-password and external-OIDC manifest rendering;
- local password Secret/environment omission in external-OIDC mode;
- active pruning of stale password-login resources during migration;
- mode-aware password maintenance and `doctor.sh` conflict/drift diagnostics;
- static/render and isolated live install/reinstall coverage.

Remaining production acceptance/operational work:

- operate and back up Authelia/FreeIPA through an approved external deployment process;
- prove the required FreeIPA OTP bind mechanism and replay rejection;
- complete final production-browser tests for group denial, logout, session expiry, and WebSockets;
- add Secret-backed confidential-client credentials if a selected provider requires them.

The installer should not automatically configure a user's private FreeIPA or Authelia instance from installation-specific values. Keep those credentials and certificates operator-owned.

## Maintenance and upgrade ownership

### Hermes

Use the repository's lifecycle commands:

```bash
./doctor.sh
./maintain.sh status
./maintain.sh backup ./backups/hermes-YYYYmmddTHHMMSSZ.age
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.age --full --dry-run
```

A later `install.sh` run renders from the repository template and reapplies installer-owned resources. Do not treat a manual Deployment patch as durable configuration.[1][3]

### Authelia

Back up separately:

- Authelia configuration;
- Authelia database/PVC;
- session/storage encryption keys;
- OIDC signing keys;
- OIDC client definitions and secrets;
- FreeIPA CA certificate;
- OPNsense routing/TLS configuration.

Authelia's OIDC provider is documented by the project as an open-beta feature. Pin the image/chart, read the release notes, and test the exact Dashboard/WebUI callbacks before making it the only production login path.[9]

### Restore order

1. Restore FreeIPA reachability and CA trust.
2. Restore Authelia state and keys.
3. Verify Authelia health and OIDC discovery.
4. Install/restore Hermes with `external-oidc`.
5. Verify exact callbacks and absence of local password variables.
6. Test a non-production FreeIPA account.

Do not treat a Hermes backup as an Authelia backup when Authelia is deployed separately. If Authelia keys are lost, existing OIDC sessions/tokens may become invalid; document that as an expected recovery consequence.

## Security invariants

- No local password may remain as an unintentional alternative to external MFA.
- FreeIPA LDAP uses LDAPS or StartTLS with CA validation.
- The Authelia LDAP service account is least privilege and has no administrator role or OTP token.
- User LDAP authentication uses live bind mode, not stored password-hash verification, when FreeIPA OTP semantics are required.
- OIDC clients use exact redirect URIs and separate client identities.
- WebUI group/claim allow-lists are explicit.
- Browserless remains internal and token-protected.
- Dashboard/WebUI Services remain ClusterIP unless a private boundary is deliberate.
- WebSockets, logout, session expiry, health probes, and direct-Service paths are tested.
- Secrets, OTP seeds, authorization codes, session cookies, and tokens are never logged or committed.

## QA acceptance matrix

| Test | Expected result |
|---|---|
| FreeIPA user without OTP | Result matches explicit FreeIPA policy |
| Password-only after OTP enforcement | Rejected |
| Password + fresh FreeIPA OTP/control | Accepted only if Authelia sends the FreeIPA-required bind mechanism |
| Same OTP reused | Rejected by FreeIPA when the required OTP path is actually used |
| Expired/wrong OTP | Rejected |
| User outside allowed group | OIDC/Hermes access rejected |
| Dashboard OIDC | Authenticated Dashboard opens |
| WebUI OIDC | Authenticated WebUI opens |
| WebUI WebSocket/chat | Authenticated connection works |
| Local password in `external-oidc` | No bypass |
| Direct Service access | Cannot bypass intended boundary |
| Reinstall | OIDC configuration and no-bypass invariant persist |
| Hermes backup dry-run | External Authelia scope is clear |
| Authelia restore | Separate authentication restore succeeds |

A real browser is required for Dashboard/WebUI acceptance; curl alone is insufficient for browser login and WebSocket behavior.[4]

## Sources

[1] https://github.com/Bitbull-Ideas/kube.hermes_setup
[2] https://github.com/Bitbull-Ideas/kube.hermes_setup/blob/main/docs/security.md
[3] https://github.com/Bitbull-Ideas/kube.hermes_setup/blob/main/docs/operations.md
[4] https://github.com/Bitbull-Ideas/kube.hermes_setup/blob/main/docs/qa.md
[5] https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/web-dashboard.md
[6] https://github.com/nesquena/hermes-webui/blob/master/api/auth_oidc.py
[7] https://github.com/authelia/authelia/blob/master/docs/content/integration/ldap/freeipa.md
[8] https://github.com/authelia/authelia/blob/master/internal/authentication/ldap_user_provider.go
[9] https://github.com/authelia/chartrepo/releases/tag/authelia-0.11.6
[10] https://github.com/freeipa/freeipa/pull/7618
