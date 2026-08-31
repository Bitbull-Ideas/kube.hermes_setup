# Authelia + FreeIPA SSO for Hermes — Setup Guide

This guide installs Hermes with `kube.hermes_setup`, then adds Authelia OIDC backed by FreeIPA LDAP. It focuses only on settings relevant to SSO; use the repository's normal defaults and operational documentation for model, storage, Browserless, bootstrap, and other Hermes settings.

For architecture, authentication modes, maintenance, upgrades, and backup ownership, see [`authelia-freeipa-sso-overview.md`](authelia-freeipa-sso-overview.md).

Use a dedicated local directory such as `authelia-sso/` for temporary QA inputs and rendered files. It is not part of the repository's current installer output and must be ignored or removed before commit:

```bash
mkdir -p authelia-sso
chmod 700 authelia-sso
```

The commands below are for an isolated QA deployment. They are not a production installer implementation. Before using them against a production cluster, create a reviewed private values file, use your approved Secret-management process, pin versions/digests, and complete the acceptance matrix.

## Result

For **native OIDC**, the browser flow is:

```text
Browser -> Hermes Dashboard/WebUI
             -> redirect to Authelia OIDC
             -> FreeIPA authentication / OTP policy
             -> OIDC callback to Hermes
             -> Hermes application session
```

For **forward-auth/trusted-proxy**, the proxy is inline on each request:

```text
Browser -> OPNsense / Traefik / forward-auth proxy
             -> Authelia authorization check
             -> Hermes Dashboard/WebUI
```

The existing FreeIPA TOTP token remains owned by FreeIPA. Whether it can be reused through Authelia is an explicit compatibility question, not an assumption: the test must prove that Authelia's LDAP client performs the FreeIPA-required OTP bind, not merely a password-only LDAP bind. Do not enroll an Authelia-managed TOTP token unless you intentionally want a second, separate MFA enrollment.

## Prerequisites

You need:

- a working Kubernetes/k3s context;
- Traefik or another Ingress controller;
- public or private DNS for three hostnames;
- TLS covering those hostnames;
- a FreeIPA least-privilege LDAP lookup account;
- a non-admin QA FreeIPA user;
- a FreeIPA group allowed to use Hermes;
- the FreeIPA CA certificate;
- a FreeIPA policy and client path that can be tested for LDAP OTP enforcement;

Example values:

```text
FreeIPA LDAP URL:       ldaps://idm.example.invalid:636
FreeIPA base DN:        dc=example,dc=invalid
FreeIPA bind DN:        uid=authelia-bind,cn=users,cn=compat,dc=example,dc=invalid
QA username:            authelia-test
QA allowed group:       hermes-qa-users
Authelia URL:           https://sso.example.com
Dashboard URL:          https://hermes-admin.example.com
WebUI URL:              https://hermes.example.com
```

The QA user should be temporary, non-admin, and removed or disabled after testing.

## 1. Install Hermes with SSO-relevant settings

Use the normal Hermes installer and keep the current namespace private until the external provider is ready:

```bash
cp examples/hermes.env.example hermes.env
chmod 600 hermes.env
```

Set the normal Hermes values according to the repository documentation. For SSO, initially keep the backward-compatible local mode while proving the base installation:

```dotenv
HERMES_NAMESPACE=hermes
HERMES_AGENT_ENABLED=true
HERMES_DASHBOARD_ENABLED=true
HERMES_WEBUI_ENABLED=true
HERMES_BROWSER_ENABLED=true

WEBUI_HOST=hermes.example.com
DASHBOARD_HOST=hermes-admin.example.com
INGRESS_CLASS_NAME=traefik
TRAEFIK_ENTRYPOINT=websecure
TLS_ENABLED=true
TLS_SECRET_NAME=

# Current repository behavior during the bootstrap phase.
DASHBOARD_AUTH_USER=admin
DASHBOARD_AUTH_PASSWORD=
```

Leave unrelated settings at repository defaults unless your deployment requires changes. Do not place FreeIPA passwords, CA material, OTP seeds, or Authelia keys in `hermes.env`.

Install and verify the base Hermes deployment:

```bash
set -a
. ./hermes.env
set +a
ENV_FILE=./hermes.env ./install.sh
kubectl -n "${HERMES_NAMESPACE:?HERMES_NAMESPACE is required}" get deploy,pods,svc,ingress,pvc -o wide
./doctor.sh
```

Verify the base local login before adding SSO. This separates Hermes installation problems from Authelia/FreeIPA problems.

## 2. Prepare FreeIPA

### 2.1 Create or select the LDAP lookup account

Use a dedicated service account with only the permissions required to:

- search users;
- read the selected user attributes;
- search groups;
- read group membership.

It should not be an administrator and does not need an OTP token.

The service account DN can be under the FreeIPA account tree or the compatibility tree if that is how the account is exposed. The search base should normally be the canonical domain base so Authelia can find canonical `person` and `groupOfNames` entries.

### 2.2 Create or select the QA user/group

Example:

```text
Username: authelia-test
Allowed group: hermes-qa-users
```

Confirm that the user is a member of the allowed group. Do not send the password or OTP seed into Git or documentation.

### 2.3 Fetch and verify the FreeIPA CA

For initial bootstrap only, fetch the CA using a trusted endpoint path:

```bash
mkdir -p authelia-sso
umask 077
curl --fail --silent --show-error --insecure \
  https://idm.example.invalid/ipa/config/ca.crt \
  --output authelia-sso/freeipa-ca.crt
```

The initial `--insecure` fetch must be followed by independent verification. Inspect the CA and verify it against the LDAPS server certificate:

```bash
openssl x509 -in authelia-sso/freeipa-ca.crt -noout \
  -subject -issuer -serial -dates -fingerprint -sha256

openssl s_client -connect idm.example.invalid:636 \
  -servername idm.example.invalid -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/{f=1} f{print} /END CERTIFICATE/{exit}' \
  > authelia-sso/freeipa-leaf.crt

openssl verify -CAfile authelia-sso/freeipa-ca.crt \
  authelia-sso/freeipa-leaf.crt
rm -f authelia-sso/freeipa-leaf.crt
```

Expected:

```text
authelia-sso/freeipa-leaf.crt: OK
```

### 2.4 Test the service bind before deploying Authelia

Use an LDAP client with the CA configured. Do not put the password in shell history. The important checks are:

```text
LDAPS connection succeeds
service-account bind succeeds
QA user search returns the intended canonical user DN
allowed group search returns hermes-qa-users
```

If the bind fails with LDAP result 49, stop and correct the DN/password/account state before continuing.

## 3. Deploy Authelia

Keep Authelia separate from the Hermes namespace unless you have explicitly decided that the repository owns its resources.

### 3.1 Create the namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: hermes-auth
  labels:
    purpose: hermes-authentication
```

Save that block as `authelia-sso/namespace.yaml`, then apply it:

```bash
cat > authelia-sso/namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: hermes-auth
  labels:
    purpose: hermes-authentication
EOF
kubectl apply -f authelia-sso/namespace.yaml
kubectl get namespace hermes-auth
```

### 3.2 Pin the chart/image

The Authelia chart is pre-1.0; pin both chart and image. The example versions are illustrative and must be reviewed before deployment:

```bash
helm repo add authelia https://charts.authelia.com
helm repo update
helm show chart authelia/authelia --version 0.11.6
helm pull authelia/authelia --version 0.11.6 --destination authelia-sso/chart
sha256sum authelia-sso/chart/authelia-0.11.6.tgz
# For release authelia-0.11.6, expected SHA-256 is:
# 16ab42ee63a8539c4294250faebb92e719cc5022382b79a5c83aeac65a8f4fc5
```

Example pins:

```text
Chart:  0.11.6
Image:  4.39.20
```

### 3.3 Generate Authelia secrets locally

Use a protected shell or a secret manager. For disposable QA:

```bash
export AUTHELIA_SESSION_SECRET="$(openssl rand -hex 32)"
export AUTHELIA_STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)"
export AUTHELIA_RESET_PASSWORD_JWT_SECRET="$(openssl rand -hex 32)"
export AUTHELIA_OIDC_HMAC_SECRET="$(openssl rand -hex 32)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out authelia-sso/oidc-jwk.pem
chmod 600 authelia-sso/oidc-jwk.pem
```

Create Secrets without committing rendered YAML:

```bash
kubectl -n hermes-auth create secret generic authelia-freeipa-ca \
  --from-file=ca.crt=authelia-sso/freeipa-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n hermes-auth create secret generic oidc-jwk \
  --from-file=oidc-jwk.pem=authelia-sso/oidc-jwk.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

Create the Secret containing password/key files with a fail-closed shell. The `trap` removes temporary files whether the Secret command succeeds or fails:

```bash
set -euo pipefail
umask 077
mkdir -p authelia-sso
: "${FREEIPA_BIND_PASSWORD:?set FREEIPA_BIND_PASSWORD in a protected shell}"
: "${AUTHELIA_SESSION_SECRET:?set AUTHELIA_SESSION_SECRET in a protected shell}"
: "${AUTHELIA_STORAGE_ENCRYPTION_KEY:?set AUTHELIA_STORAGE_ENCRYPTION_KEY in a protected shell}"
: "${AUTHELIA_RESET_PASSWORD_JWT_SECRET:?set AUTHELIA_RESET_PASSWORD_JWT_SECRET in a protected shell}"
: "${AUTHELIA_OIDC_HMAC_SECRET:?set AUTHELIA_OIDC_HMAC_SECRET in a protected shell}"
trap 'rm -f authelia-sso/ldap.password authelia-sso/session.secret \
  authelia-sso/storage.encryption.key authelia-sso/reset-password.jwt.secret \
  authelia-sso/oidc.hmac.secret' EXIT

printf '%s' "$FREEIPA_BIND_PASSWORD" > authelia-sso/ldap.password
printf '%s' "$AUTHELIA_SESSION_SECRET" > authelia-sso/session.secret
printf '%s' "$AUTHELIA_STORAGE_ENCRYPTION_KEY" > authelia-sso/storage.encryption.key
printf '%s' "$AUTHELIA_RESET_PASSWORD_JWT_SECRET" > authelia-sso/reset-password.jwt.secret
printf '%s' "$AUTHELIA_OIDC_HMAC_SECRET" > authelia-sso/oidc.hmac.secret

kubectl -n hermes-auth create secret generic authelia-secrets \
  --from-file=authentication.ldap.password.txt=authelia-sso/ldap.password \
  --from-file=session.encryption.key=authelia-sso/session.secret \
  --from-file=storage.encryption.key=authelia-sso/storage.encryption.key \
  --from-file=identity_validation.reset_password.jwt.hmac.key=authelia-sso/reset-password.jwt.secret \
  --from-file=identity_providers.oidc.hmac.key=authelia-sso/oidc.hmac.secret \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `trap` removes the temporary files when the block exits. Do not source a file containing these values from shell history or commit it.

### 3.4 Configure Authelia values

Create a local `authelia-sso/values.yaml` with sanitized structure like this:

```yaml
image:
  tag: '4.39.20'
  pullPolicy: IfNotPresent

configMap:
  authentication_backend:
    ldap:
      enabled: true
      implementation: freeipa
      address: ldaps://idm.example.invalid:636
      base_dn: dc=example,dc=invalid
      user: uid=authelia-bind,cn=users,cn=compat,dc=example,dc=invalid
      permit_unauthenticated_bind: false
      users_filter: '(&({username_attribute}={input})(objectClass=person)(!(nsAccountLock=TRUE)))'
      groups_filter: '(&(member={dn})(objectClass=groupOfNames))'
      password:
        value: ''
        path: authentication.ldap.password.txt

  storage:
    local:
      enabled: true
      path: /config/db.sqlite3
  notifier:
    filesystem:
      enabled: true
      filename: /config/notification.txt
  session:
    remember_me: -1
    cookies:
      - subdomain: sso
        domain: example.com
        default_redirection_url: https://hermes.example.com
        same_site: lax
        inactivity: 2h
        expiration: 12h

  identity_providers:
    oidc:
      enabled: true
      lifespans:
        custom:
          hermes-session-12h:
            id_token: 12h
      hmac_secret:
        value: ''
      jwks:
        - key_id: hermesqa
          algorithm: RS256
          use: sig
          key:
            path: /secrets/oidc-jwk/oidc-jwk.pem
      claims_policies:
        hermes:
          id_token:
            - preferred_username
            - groups
          access_token: []
          custom_claims: {}
      authorization_policies:
        hermes_users:
          default_policy: deny
          rules:
            - policy: one_factor
              subject:
                - group:hermes-qa-users
      clients:
        - client_id: hermes-dashboard
          client_name: Hermes Dashboard QA
          public: true
          redirect_uris:
            - https://hermes-admin.example.com/auth/callback
          scopes: [openid, profile, email, groups]
          authorization_policy: hermes_users
          claims_policy: hermes
          lifespan: hermes-session-12h
          consent_mode: auto
        - client_id: hermes-webui
          client_name: Hermes WebUI QA
          public: true
          redirect_uris:
            - https://hermes.example.com/api/auth/oidc/callback
          scopes: [openid, profile, email, groups]
          authorization_policy: hermes_users
          claims_policy: hermes
          lifespan: hermes-session-12h
          consent_mode: auto

pod:
  kind: Deployment

secret:
  existingSecret: authelia-secrets
  additionalSecrets:
    oidc-jwk:
      path: oidc-jwk
      items:
        - key: oidc-jwk.pem
          path: oidc-jwk.pem

certificates:
  existingSecret: authelia-freeipa-ca

persistence:
  enabled: true
  storageClass: local-path
  size: 1Gi
```

The pinned chart's schema must be checked before applying. In chart `0.11.6`, the LDAP backend defaults to the live `bind` authentication path; do not replace it with stored password-hash verification when preserving FreeIPA OTP semantics. If a later chart exposes an explicit `authentication_method`, set it to `bind` and validate the rendered configuration.

```bash
CHART=authelia-sso/chart/authelia-0.11.6.tgz
helm lint "$CHART" \
  --values authelia-sso/values.yaml
helm template authelia-qa "$CHART" \
  --namespace hermes-auth \
  --values authelia-sso/values.yaml \
  > authelia-sso/rendered.yaml
kubectl apply --dry-run=server -f authelia-sso/rendered.yaml >/dev/null
```

Review object names, Secret references, volume mounts, callback URLs, and image tags. Do not commit `rendered.yaml` if it contains installation-specific values.

### 3.5 Configure the Authelia Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: authelia
  namespace: hermes-auth
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  rules:
    - host: sso.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: authelia-qa
                port:
                  number: 80
```

Save that block as `authelia-sso/ingress.yaml`:

```bash
cat > authelia-sso/ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: authelia
  namespace: hermes-auth
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  rules:
    - host: sso.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: authelia-qa
                port:
                  number: 80
EOF
```

Apply and verify:

```bash
kubectl apply -f authelia-sso/rendered.yaml
kubectl apply -f authelia-sso/ingress.yaml
kubectl -n hermes-auth rollout status deploy/authelia-qa --timeout=180s
kubectl -n hermes-auth get pod,svc,ingress,pvc -o wide
curl --fail --silent --show-error https://sso.example.com/api/health
curl --fail --silent --show-error \
  https://sso.example.com/.well-known/openid-configuration \
  | jq '{issuer,authorization_endpoint,token_endpoint,jwks_uri}'
```

If the pinned chart creates a DaemonSet instead of a Deployment, use its actual workload kind in the rollout command.

## 4. Configure Hermes for external OIDC

The current repository supports the `external-oidc` application wiring but does not install or manage Authelia/FreeIPA. The setup below is an isolated QA/integration procedure until the external IdP is operated through your approved deployment process. Do not treat a manually patched production Deployment as durable.

`./configure.sh` asks for the authentication mode directly: choose `external-oidc` when prompted and it collects the issuer, client IDs, public/redirect URLs, and allow claim/values interactively, writing them straight to `hermes.env` — the local-password username/password prompts are skipped entirely. The values below describe exactly what the wizard collects, for reference or for manually editing an existing `hermes.env`.

The intended SSO-relevant environment is:

```dotenv
HERMES_AUTH_MODE=external-oidc
HERMES_AUTH_SESSION_MAX_TTL_SECONDS=43200
HERMES_AUTH_SESSION_IDLE_TTL_SECONDS=7200

HERMES_DASHBOARD_OIDC_ISSUER=https://sso.example.com
HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-dashboard
HERMES_DASHBOARD_OIDC_SCOPES="openid profile email groups"
HERMES_DASHBOARD_PUBLIC_URL=https://hermes-admin.example.com

HERMES_WEBUI_OIDC_ISSUER=https://sso.example.com
HERMES_WEBUI_OIDC_CLIENT_ID=hermes-webui
HERMES_WEBUI_OIDC_REDIRECT_URI=https://hermes.example.com/api/auth/oidc/callback
HERMES_WEBUI_OIDC_SCOPES="openid profile email groups"
HERMES_WEBUI_OIDC_ALLOW_CLAIM=groups
HERMES_WEBUI_OIDC_ALLOW_VALUES=hermes-qa-users
```

`HERMES_AUTH_SESSION_MAX_TTL_SECONDS` is the shared 12-hour maximum. The
installer injects it into WebUI as `HERMES_WEBUI_SESSION_TTL`; configure the
same duration as Authelia's cookie `expiration` and the Dashboard client's OIDC
ID-token lifespan. `HERMES_AUTH_SESSION_IDLE_TTL_SECONDS` documents the
Authelia-only two-hour inactivity policy. Dashboard and WebUI do not currently
provide equivalent sliding-idle controls. Keep Authelia `remember_me: -1` so a
remember-me selection cannot override the 12-hour maximum.

The installer implementation must omit these local-password variables in this mode:

```text
HERMES_DASHBOARD_BASIC_AUTH_USERNAME
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
HERMES_WEBUI_PASSWORD
```

Verify names only:

```bash
for deploy in hermes-dashboard hermes-webui; do
  kubectl -n "$HERMES_NAMESPACE" get deploy "$deploy" -o json \
    | jq -r '.spec.template.spec.containers[].env[]?.name' \
    | grep -E 'BASIC_AUTH|WEBUI_PASSWORD' \
    && { echo "local auth still present in $deploy"; exit 1; } \
    || true
done
```

## 5. Migrate an existing local-password installation

This section applies when Hermes is already running with the repository's default shared Dashboard/WebUI password and you want to cut over to `external-oidc` without recreating the Hermes PVCs or losing application state.

### 5.1 Preconditions

Do not change Hermes authentication until the external provider is independently ready. Verify:

```bash
set -a
. ./hermes.env
set +a

OIDC_ISSUER=https://sso.example.com

curl --fail --silent --show-error \
  "$OIDC_ISSUER/api/health"

curl --fail --silent --show-error \
  "$OIDC_ISSUER/.well-known/openid-configuration" \
  | jq '{issuer,authorization_endpoint,token_endpoint,jwks_uri}'
```

Before cutover, complete a browser login against Authelia with a temporary FreeIPA user and confirm that:

- the intended FreeIPA user and group are found;
- the Dashboard and WebUI OIDC clients have exact callback URIs;
- the allow-list claim is present in the ID token;
- the user is permitted by the intended group/claim policy;
- the FreeIPA OTP behavior is verified or explicitly marked blocked as described in section 6.3.

### 5.2 Record the current state

Record non-secret resource identities and authentication mode before changing anything:

```bash
NS="${HERMES_NAMESPACE:?HERMES_NAMESPACE is required}"

kubectl -n "$NS" get deploy,ingress,pvc -o wide
kubectl -n "$NS" get secret hermes-dashboard-auth \
  -o custom-columns=NAME:.metadata.name,TYPE:.type
kubectl -n "$NS" get pvc \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,STATUS:.status.phase
```

Do not decode or print the current local password.

### 5.3 Create a rollback backup

Create an encrypted Hermes backup before switching modes:

```bash
backup="./backups/hermes-pre-oidc-$(date -u +%Y%m%dT%H%M%SZ).age"
./maintain.sh backup "$backup" --password-file /secure/hermes-backup.pass
sha256sum -c "$backup.sha256"

ENV_FILE=./hermes.env ./maintain.sh restore "$backup" \
  --full --dry-run --password-file /secure/hermes-backup.pass
```

The backup is sensitive because it contains Hermes PVC data and application Secrets. Keep it mode `0600` in approved protected storage. The Authelia database, keys, and configuration need their own backup; the Hermes archive is not an Authelia backup.

If exact restoration of the previous shared password is required, preserve it through the approved encrypted Secret-management process before cutover. Do not place it in `hermes.env`, shell history, documentation, or an unencrypted YAML export.

### 5.4 Update the installer source of truth

Edit the same private `hermes.env` used for the current installation. Keep the Namespace, PVC, hostnames, images, bootstrap, and unrelated settings unchanged. Replace the local authentication selection with:

```dotenv
HERMES_AUTH_MODE=external-oidc
HERMES_AUTH_SESSION_MAX_TTL_SECONDS=43200
HERMES_AUTH_SESSION_IDLE_TTL_SECONDS=7200

HERMES_OIDC_ISSUER=https://sso.example.com
HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-dashboard
HERMES_DASHBOARD_OIDC_SCOPES="openid profile email groups"
HERMES_DASHBOARD_PUBLIC_URL=https://hermes-admin.example.com

HERMES_WEBUI_OIDC_CLIENT_ID=hermes-webui
HERMES_WEBUI_OIDC_SCOPES="openid profile email groups"
HERMES_WEBUI_OIDC_REDIRECT_URI=https://hermes.example.com/api/auth/oidc/callback
HERMES_WEBUI_OIDC_ALLOW_CLAIM=groups
HERMES_WEBUI_OIDC_ALLOW_VALUES=hermes-qa-users
```

Remove `DASHBOARD_AUTH_PASSWORD` from the private file if it was previously stored there. `DASHBOARD_AUTH_USER` is ignored outside `local-password` mode and may also be removed.

Do not change `HERMES_NAMESPACE`, delete PVCs, or create a second Hermes installation for the migration.

### 5.5 Render and inspect before apply

Use a separate local render directory and inspect the rendered authentication boundary before changing the live Deployments:

```bash
set -a
. ./hermes.env
set +a

render_dir="$(mktemp -d)"
trap 'rm -rf -- "$render_dir"' EXIT

ENV_FILE=./hermes.env \
HERMES_RENDER_DIR="$render_dir" \
HERMES_INSTALL_LIB_ONLY=true \
  bash -c 'source ./install.sh; load_env; prepare_paths; prepare_defaults; validate; export API_SERVER_KEY_REVISION=preflight-resource-version; render_manifest'

for deploy in hermes-dashboard hermes-webui; do
  python3 - "$render_dir/hermes.yaml" "$deploy" <<'PY'
import sys
import yaml

manifest, wanted = sys.argv[1:]
for document in yaml.safe_load_all(open(manifest)):
    if document and document.get("kind") == "Deployment" and document["metadata"]["name"] == wanted:
        env = {
            item["name"]: item.get("value")
            for item in document["spec"]["template"]["spec"]["containers"][0].get("env", [])
        }
        names = set(env)
        forbidden = {
            "HERMES_DASHBOARD_BASIC_AUTH_USERNAME",
            "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD",
            "HERMES_WEBUI_PASSWORD",
        }
        overlap = forbidden.intersection(names)
        if overlap:
            raise SystemExit(f"local authentication still rendered for {wanted}: {sorted(overlap)}")
        if wanted == "hermes-webui" and env.get("HERMES_WEBUI_SESSION_TTL") != "43200":
            raise SystemExit("WebUI session maximum is not 12 hours")
        print(f"{wanted}: local password variables absent")
        break
else:
    raise SystemExit(f"deployment not found: {wanted}")
PY
done

kubectl apply --dry-run=server -f "$render_dir/hermes.yaml" >/dev/null
```

Also verify that the rendered manifest omits the Dashboard password-login rewrite resources:

```bash
if grep -Eq 'name: hermes-dashboard-login($|-rewrite$)' "$render_dir/hermes.yaml"; then
  echo 'ERROR: password-login route still rendered' >&2
  exit 1
fi
```

### 5.6 Apply the cutover

The installer stages the cutover safely: it retains the previous `hermes-dashboard-auth` Secret while the OIDC workload specifications are applied and deletes it only after all enabled external-OIDC Deployments are Ready. If rendering, apply, or rollout fails before then, the previous ReplicaSets remain restartable with the old Secret.

Run the normal installer against the existing Namespace:

```bash
ENV_FILE=./hermes.env ./install.sh
./doctor.sh
```

The installer should:

- retain the existing PVCs and application data;
- remove `hermes-dashboard-auth`;
- remove local password environment references;
- remove the Dashboard password-login rewrite path;
- add Dashboard and WebUI OIDC settings;
- roll out both applications.

### 5.7 Verify the migrated installation

Verify live environment names and resource state without printing Secret values:

```bash
NS="${HERMES_NAMESPACE:?HERMES_NAMESPACE is required}"

for deploy in hermes-dashboard hermes-webui; do
  kubectl -n "$NS" get deploy "$deploy" -o json \
    | jq -r '.spec.template.spec.containers[].env[]?.name' \
    | grep -E 'BASIC_AUTH|WEBUI_PASSWORD' \
    && { echo "local authentication still present in $deploy"; exit 1; } \
    || true
done

if kubectl -n "$NS" get secret hermes-dashboard-auth >/dev/null 2>&1; then
  echo 'ERROR: local authentication Secret still exists' >&2
  exit 1
fi

if kubectl -n "$NS" get ingress hermes-dashboard-login >/dev/null 2>&1; then
  echo 'ERROR: Dashboard password-login Ingress still exists' >&2
  exit 1
fi

kubectl -n "$NS" rollout status deploy/hermes-dashboard --timeout=600s
kubectl -n "$NS" rollout status deploy/hermes-webui --timeout=600s
```

Then use a real browser to verify:

1. Dashboard redirects to Authelia and returns to `/auth/callback`.
2. WebUI redirects to Authelia and returns to `/api/auth/oidc/callback`.
3. A user outside the allowed claim/group is rejected.
4. Dashboard and WebUI authenticated content loads.
5. WebUI chat/WebSocket works.
6. WebUI and Dashboard application sessions expire after 12 hours even with activity.
7. The Authelia SSO session requires authentication after two hours of inactivity or 12 hours absolute.
8. Authelia does not offer or honor remember-me for this policy.
9. The former local password is rejected and no password-login route is available.

Finally rerun the installer unchanged and repeat the no-local-auth checks. This proves that the migration is durable rather than a one-time live patch.

### 5.8 Roll back to local-password

If OIDC fails during cutover, restore local access through the installer source of truth:

```dotenv
HERMES_AUTH_MODE=local-password
DASHBOARD_AUTH_USER=admin
DASHBOARD_AUTH_PASSWORD=
```

Then run:

```bash
ENV_FILE=./hermes.env ./install.sh
./doctor.sh
```

With a blank password and no existing `hermes-dashboard-auth` Secret, the installer generates a new local password. Retrieve it only from a trusted administrator terminal:

```bash
./maintain.sh show-passwords
```

This restores local access but does not preserve the previous password. If exact full-state rollback is required, use the verified encrypted pre-cutover backup and the normal `restore --full` procedure, understanding that full restore affects the Namespace resources and PVC payloads recorded in the backup.

After rollback, verify that:

```text
hermes-dashboard-auth exists
Dashboard BasicAuth variables exist
HERMES_WEBUI_PASSWORD exists
Dashboard password-login route exists
valid local password succeeds
OIDC is no longer presented as the active application login path
```

## 6. Test the complete flow

### 6.1 Baseline without FreeIPA OTP

Before enrolling OTP, this proves only the baseline service-account lookup and password-only user bind. It does **not** prove FreeIPA OTP compatibility. The important checks are:

### 6.2 Browser OIDC test

Open each application in a real browser:

```text
https://hermes-admin.example.com
https://hermes.example.com
```

For each:

1. Select self-hosted OIDC.
2. Confirm redirect to Authelia.
3. Authenticate with the temporary FreeIPA QA user.
4. Accept OIDC consent on first use.
5. Confirm the exact callback returns to the correct application.
6. Confirm the authenticated UI loads.
7. For WebUI, confirm chat and the authenticated WebSocket work.

### 6.3 Existing FreeIPA OTP compatibility test

This is the decisive test for your requirement. FreeIPA's documented LDAP OTP enforcement uses an OTP bind control or the global `EnforceLDAPOTP` behavior.[10] Do not infer success from a login that accepts a concatenated password+OTP string unless the FreeIPA client path explicitly documents that format.

First establish the FreeIPA policy and the client capability:

```text
FreeIPA OTP enforcement mode:       ____________________
Required LDAP control, if any:      ____________________
Authelia LDAP client sends it:      yes / no / unknown
Password+OTP concatenation required: yes / no / unknown
```

If the required control is not sent by Authelia's LDAP client, mark the reuse test **blocked/not supported**. Do not weaken FreeIPA enforcement and do not claim that Authelia preserves the existing OTP token. The fallback choices are:

- use an Authelia-managed second factor, accepting a separate enrollment; or
- implement/test a FreeIPA-compatible authentication bridge that can perform the required OTP bind before issuing OIDC.

If the required FreeIPA LDAP OTP path is supported, test the actual credential/control format specified by FreeIPA:

```text
password-only before OTP enforcement:  policy-dependent baseline
password-only after OTP enforcement:  expected rejection
password + fresh OTP/control:          expected success
same OTP/control reused:               expected rejection
expired OTP:                            expected rejection
wrong password + fresh OTP:             expected rejection
```

Capture only sanitized pass/fail results and FreeIPA/Authelia version information. Do not log the password, OTP, seed, LDAP request contents, authorization code, session cookie, or token.

### 6.4 Authorization and bypass tests

Verify:

```text
QA user in allowed group:       allowed
valid FreeIPA user outside it:  rejected
local Hermes password:          unavailable in external-oidc mode
Direct ClusterIP/Service path:  cannot bypass intended boundary
Logout:                         removes/invalidates expected sessions
Session expiry:                 requires login again
```

Do not log passwords, OTPs, seeds, authorization codes, cookies, or tokens. Record only sanitized pass/fail results and timestamps.

## 7. Troubleshooting

### LDAP result 49

The LDAP bind credentials are invalid or the DN/account state is wrong. Verify the service DN, password, account lock/expiry state, and whether the selected DN is bindable.

### User search returns no entries

Use the canonical FreeIPA base DN rather than only `cn=compat`. Confirm the user filter matches `objectClass=person` and that the service account can read the canonical user entry.

### Group allow-list denies a valid user

The group may not be present in the OIDC ID token. Configure an Authelia claims policy to include `groups` in the ID token, or temporarily use a verified immutable subject claim for diagnosis. Then restore group-based authorization.

### Redirect URI mismatch

Compare the exact runtime callback with the registered client URI, including scheme, hostname, path, trailing slash behavior, and proxy prefix.

### WebUI returns `OIDC identity is not allowed`

Inspect the WebUI allow claim and values. WebUI validates the ID token claims itself; an OIDC client requesting a scope does not guarantee the desired claim is present in the ID token.[6]

### Local password still works

Stop. This is an MFA bypass in external mode. Inspect the Dashboard/WebUI Deployment environment and the installer source of truth. Do not proceed to production until the local path is removed or explicitly isolated.

## 8. Upgrade, backup, and cleanup

Back up Hermes with the repository tools:

```bash
./maintain.sh backup ./backups/hermes-YYYYmmddTHHMMSSZ.age
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.age \
  --full --dry-run --password-file /secure/hermes-backup.pass
```

Back up Authelia separately:

```text
Authelia configuration
Authelia database/PVC
session/storage encryption keys
OIDC signing keys
OIDC client definitions/secrets
FreeIPA CA certificate
OPNsense routing/TLS configuration
```

Restore in this order:

```text
FreeIPA reachability and CA trust
Authelia state and keys
Authelia health and OIDC discovery
Hermes external-oidc configuration
Dashboard/WebUI callbacks and WebSocket tests
```

After QA:

```bash
kubectl delete namespace hermes-auth --wait=true --timeout=120s
if kubectl get namespace hermes-auth >/dev/null 2>&1; then
  echo 'ERROR: hermes-auth namespace still exists after cleanup' >&2
  exit 1
fi
rm -rf -- authelia-sso
```

Separately disable/delete the temporary FreeIPA service and test accounts. Rotate or remove any password used during testing.

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
