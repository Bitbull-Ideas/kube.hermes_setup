# QA and live acceptance

The policy follows established QA practice: define representative test data and explicit graders/acceptance criteria before evaluating behavior ([OpenAI eval guidance](https://developers.openai.com/api/docs/guides/evals)); validate the actual deployed system rather than only generated artifacts; and use small, isolated deployments with explicit evaluation before broader rollout ([Google SRE canarying guidance](https://sre.google/workbook/canarying-releases/)).

This repository deploys a multi-container application. Static shell, Python, and YAML tests are necessary but do not prove that the deployed images start or that the user-facing system works.

## Mandatory test policy

For any change affecting `configure.sh`, `install.sh`, `maintain.sh`, `doctor.sh`, `manifests/`, bootstrap profiles, Secrets, PVCs, optional components, ingress, authentication, Browserless, WebUI, Ansible, or SSH:

- run the repository-local tests;
- run a real deployment on a fresh disposable Linux/K3s VM or an explicitly named real test VM;
- test every enabled component, not only `hermes-agent`;
- inspect startup logs and Kubernetes events for every deployment;
- rerun the installer unchanged and verify stable persistent state;
- report any skipped live gate as **blocked**, never as passed.

An Agent-only deployment is valid only for a change that is explicitly limited to Agent-only behavior and has no effect on shared manifests, credentials, bootstrap, optional components, or installer sequencing.

## Required evidence

Record the following in the PR, redacting private names, addresses, credentials, tokens, and OAuth data:

- repository commit under test;
- target type: fresh disposable VM or named real test VM;
- OS, Kubernetes/k3s version, CPU, memory, storage, and image tags;
- namespace and PVC scope, with private identifiers redacted in public text;
- readiness of node, DNS, storage provisioner, and ingress dependencies;
- init-job completion and `get deploy,pods,svc,pvc` output summary;
- logs for every enabled component, including previous container logs after a crash;
- effective non-secret environment and mounted configuration paths;
- authentication result: invalid credentials rejected and valid credentials accepted;
- browser result using real Chromium, including clean authenticated console and screenshot inspection when WebUI is enabled;
- second installer run, rollout result, PVC identity, and a hash of a persisted test artifact;
- cleanup result or explicit retained-lab decision.

## Minimum component matrix

The full acceptance run must cover these cases on clean storage:

| Case | Components | Required checks |
|---|---|---|
| agent-only | Agent | API/gateway readiness, CLI, mounted config, persistence |
| dashboard | Agent + Dashboard | dashboard rollout, login rejection/acceptance, files endpoint |
| webui | Agent + WebUI | WebUI rollout, startup logs, login rejection/acceptance, real Chromium |
| browser | Agent + Browserless | CDP URL shape, token rejection/acceptance, pressure/health |
| full | Agent + Dashboard + WebUI + Browserless | all checks together, NetworkPolicy and ingress |
| reinstall | same as full | unchanged reinstall, Secret hashes, PVC identity/data |
| failure | one invalid input or dependency | fail before destructive apply, no silent credential rotation |

A test that disables WebUI, Dashboard, and Browserless cannot be cited as evidence for the full or WebUI-enabled matrix.

## Backup and full-rollback acceptance

Changes to encrypted backups or `maintain.sh restore` require these additional QA gates, separate from the application component matrix:

### Local/contract tests

```bash
./tests/backup.sh
```

The backup contract test must cover:

- passphrase delivery through the PTY helper;
- protected password-file permissions;
- archive traversal/link/type rejection;
- normalized Kubernetes snapshot metadata;
- application Secret inclusion without printing values;
- `restore --full --dry-run` with no Kubernetes changes;
- refusal of K3s/version/Namespace policy mismatches without `--force`;
- forced continuation for each of those policy mismatches;
- refusal of malformed, undecryptable, or unappliable data even with `--force`.

### Live backup and preflight

On an approved isolated K3s test namespace:

```bash
backup="./backups/hermes-$(date -u +%Y%m%dT%H%M%SZ).age"
./maintain.sh backup "$backup" --password-file /secure/hermes-backup.pass
sha256sum -c "$backup.sha256"
ENV_FILE=./current_config/hermes.env ./maintain.sh restore "$backup" \
  --full --dry-run --password-file /secure/hermes-backup.pass
```

Record only redacted evidence: K3s `serverVersion.gitVersion`, snapshot resource count and kinds, archive/checksum modes, Namespace presence, and the final `No Kubernetes changes: dry-run` message. Never record Secret values or passphrases.

### Full rollback apply

A destructive apply requires explicit approval and an isolated Namespace. Verify before and after:

- the Namespace is absent or intentionally selected;
- the backup Namespace and `HERMES_NAMESPACE` match, or `--force` is deliberately being tested;
- the K3s version matches, or `--force` is deliberately being tested;
- the Namespace, PVCs, Secrets, Deployments, Services, Jobs, Ingresses, NetworkPolicies, and Middleware are recreated or reconciled;
- PVC data is restored and ownership is correct;
- original Deployment replica counts and rollout health are restored;
- no unrelated Namespace is changed;
- helper Pods and temporary plaintext files are removed.

A live `--force` test must explicitly record which policy gates were overridden. `--force` is not evidence that malformed archives or failed Kubernetes applies are acceptable; those remain hard failures.


A WebUI Pod in `CrashLoopBackOff` is a hard failure even when Agent and Dashboard are healthy. Check both current and previous logs:

```bash
kubectl -n "$HERMES_NAMESPACE" get pods -o wide
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-webui --all-containers=true --tail=250
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-webui --all-containers=true --previous --tail=250
kubectl -n "$HERMES_NAMESPACE" get events --sort-by=.lastTimestamp | tail -80
```

For packaging or image compatibility failures, identify the exact failing command and compare it with the upstream WebUI and Agent source. Do not mask a startup failure by disabling an option unless that option is proven to be honored by the image actually under test.

## Credential acceptance

For ordinary reinstall tests:

- explicit values win;
- existing Kubernetes Secrets are reused when configuration values are blank;
- missing Secrets generate values;
- malformed, empty, missing-key, RBAC, connectivity, and weak-key errors fail closed;
- compare hashes or source classifications only; never print values;
- verify that no local credential-capture file is created; compare only Kubernetes Secret source classifications, hashes, metadata, and status.

## Recommended command sequence

```bash
# Preconditions: fresh/approved test VM, working kubectl, isolated namespace.
./tests/profile-composition.sh
./tests/configure.sh
./tests/matrix.sh
./tests/ssh-identity.sh
./tests/credentials.sh
./tests/browser-cdp-convergence.sh

# Live run, with an explicitly isolated namespace and generated env file.
ENV_FILE=./current_config/hermes.env HERMES_RENDER_DIR=./current_config/artifacts ./install.sh
./doctor.sh
kubectl -n "$HERMES_NAMESPACE" get deploy,pods,svc,pvc -o wide

# Reinstall without changing the env file.
ENV_FILE=./current_config/hermes.env HERMES_RENDER_DIR=./current_config/artifacts ./install.sh
./doctor.sh
```

The exact live commands may vary by lab, but the evidence requirements do not.

## Quality rule

Do not write “tested successfully” when only syntax, fake-`kubectl`, render, or Agent-only tests passed. Use separate labels:

- `static/local`: source and hermetic tests;
- `render/schema`: generated manifest validation;
- `live/cluster`: real Kubernetes deployment;
- `runtime/acceptance`: logs, CLI, auth, browser, persistence, and reinstall.

The final status is successful only when every gate required by the change scope is green.
