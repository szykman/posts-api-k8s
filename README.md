# posts-api on Kubernetes

A small Express + TypeORM REST API ("posts"), containerized and deployed to a local
multi-node Kubernetes cluster ([kind](https://kind.sigs.k8s.io/)) in a highly available
layout: three replicas spread across three (simulated) availability zones, behind an
ingress. The deployment is packaged as a Helm chart and one script builds the whole
environment and tests it.

The original challenge statement is kept in [docs/CHALLENGE.md](docs/CHALLENGE.md).

## Quick start

Prerequisites: Docker, [kind](https://kind.sigs.k8s.io/), `kubectl`, [Helm 3](https://helm.sh/),
`openssl`, `curl`. Host ports 18080 and 18443 must be free (see `kind/cluster.yaml`).
If `kubectl`, `kind` or `helm` are missing, `scripts/install-tools.sh` installs pinned versions into
`~/.local/bin` without root. Docker is the one prerequisite it does not install.

```bash
scripts/bootstrap.sh up                  # cluster + ingress + secret + application
scripts/bootstrap.sh test                # helm test + functional smoke test
scripts/bootstrap.sh test --resilience   # ...plus the node-drain resilience test
scripts/bootstrap.sh test --upgrade      # ...plus the upgrade/rollback test (changes the release revision)
scripts/bootstrap.sh test --backup       # ...plus the database backup and restore test
scripts/bootstrap.sh down                # delete everything
```

`up` is idempotent (safe to re-run). Measured on a Linux host with 8 CPUs and 15 GiB of RAM,
with the kind node image already pulled, a full `up` from nothing took about 1 min 20 s
(two measurements: 1 min 18 s and 1 min 22 s).
The very first run also downloads images and takes longer.
On a cluster created before 0.3.0, `up` creates the missing `posts-api-token` Secret before it upgrades the release.

Every `kubectl`/`helm` call in the scripts targets the `kind-posts` context explicitly, so the
scripts cannot act on whatever cluster happens to be your current context.

After `up`:

```bash
# HTTPS only. The certificate is self-signed: --cacert makes curl verify it (no -k) and --resolve
# sends posts.local to the local port of the kind cluster.
CA="$(scripts/bootstrap.sh ca)"
curl --cacert "$CA" --resolve posts.local:18443:127.0.0.1 https://posts.local:18443/posts

# writes need the token that `up` generated (kept in the posts-api-token Secret)
curl --cacert "$CA" --resolve posts.local:18443:127.0.0.1 \
  -H "Authorization: Bearer $(scripts/bootstrap.sh token)" \
  -H 'content-type: application/json' -d '{"title":"hello","text":"world"}' https://posts.local:18443/posts
```

To open it in a browser, map the name (`127.0.0.1 posts.local` in `/etc/hosts`) and accept the certificate warning.

## Requirements checklist

| Requirement | Status | Where |
|---|---|---|
| 1. Image published in a public registry | Done | `ghcr.io/szykman/posts-api:0.3.2` (public, pulled without credentials) |
| 2. Code to deploy it to Kubernetes | Done | `helm/posts-api/` |
| 3. Exposed outside the cluster | Done | Traefik ingress, routing `posts.local` |
| 4. Highly available across 3 zones | Done | 3 replicas, `topologySpreadConstraints`, PodDisruptionBudget, probes; see [Tests](#tests) |
| Optional: reverse proxy instead of exposing the service | Done | Traefik |
| Optional: Helm | Done | `helm/posts-api/` |
| Optional: 2+ worker nodes | Done | 3 workers, one per simulated zone |
| Optional: script that builds the cluster, deploys and tests | Done | `scripts/bootstrap.sh` |
| Optional: test scenarios | Partly | Unit, smoke/functional, resilience, upgrade/rollback and backup/restore tests; no load test yet |
| Optional: script that builds the image | Done | `scripts/build.sh` (tag = chart `appVersion`, refuses to overwrite a tag) |
| Optional: private registry authentication | Done | `imagePullSecrets` in the chart, `scripts/create-pull-secret.sh`, `scripts/private-registry-demo.sh`; run against a private image on the test host (see [Private registry](#private-registry)) |
| Beyond the brief: observability | Implemented | `/metrics` on a port the ingress does not publish, PodMonitor, five alerts and a Grafana dashboard in the chart, `scripts/observability.sh`; see [Observability](#observability) |
| Optional: Terraform, remote cloud environment | Applied once as a trial | `terraform/gcp/` and `gitops/argocd/` ran on a real GKE Autopilot cluster on 22 October 2026 (bundled database, self-signed certificate); the Cloud SQL and cert-manager parts were not applied; see `docs/GKE.md` |

## Architecture

```
        127.0.0.1:18443  (kind port mapping, loopback only; 443 on the node)
                |   HTTPS, self-signed certificate (Secret posts-api-tls)
        Traefik ingress controller   (control-plane node, hostPort 443; HTTP on 18080 is not served)
                |   Host: posts.local
        Service posts-api  (ClusterIP)
        +-------+-------+
   Pod zone-a   Pod zone-b   Pod zone-c      <- topologySpreadConstraints
        +-------+-------+
        Service posts-api-db   (ClusterIP, not reachable from outside)
                |
        StatefulSet posts-api-db-0   (MariaDB 10.11, 1Gi PVC)
```

More diagrams (a request through the ingress, commit to cluster, draining a node, the GKE target) are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). For failures, see [docs/RUNBOOK.md](docs/RUNBOOK.md).

| Path | Purpose |
|---|---|
| `src/` | Application (TypeScript), the TypeORM `DataSource` (`data-source.ts`) and the initial migration |
| `Dockerfile`, `.dockerignore` | Multi-stage image build |
| `kind/cluster.yaml` | Local cluster: 1 control-plane + 3 workers labelled `zone-a/b/c` |
| `helm/posts-api/` | Helm chart: API, Service, PodDisruptionBudget, Ingress, migration hook, optional MariaDB, `helm test`; optional PodMonitor, PrometheusRule and Grafana dashboard (`dashboards/`) |
| `k8s/traefik-values.yaml` | Helm values for the Traefik ingress controller |
| `scripts/bootstrap.sh` | `up`, `test`, `down` |
| `scripts/resilience-test.sh` | Drains a worker under traffic and counts failed requests |
| `scripts/upgrade-test.sh` | Upgrades, rolls back and upgrades the release under traffic |
| `scripts/db.sh`, `scripts/backup-test.sh` | Database `backup` and `restore`, and the test that proves a restore brings a deleted post back |
| `scripts/create-pull-secret.sh`, `scripts/private-registry-demo.sh` | Create the image pull Secret; show a private image failing without it and running with it |
| `scripts/lib/ingress.sh` | Shared by the test scripts: loads the ingress certificate and wraps `curl` so it verifies it |
| `scripts/build.sh` | Builds the image tagged with the chart `appVersion`; `--push` publishes it |
| `scripts/observability.sh`, `k8s/observability-values.yaml` | `up`, `test`, `grafana`, `down`: Prometheus and Grafana on the local cluster, and the checks that they see the API |
| `scripts/install-tools.sh` | Installs pinned `kubectl`, `kind` and `helm` into `~/.local/bin` |
| `terraform/gcp/` | Regional GKE Autopilot cluster, Artifact Registry and optional Cloud SQL with HA; validated in CI; applied once as a trial without Cloud SQL |
| `gitops/argocd/` | Argo CD `Application`s for Traefik and for this chart (production values); applied once as a trial with the bundled database |
| `.github/workflows/ci.yml` | CI: tests, audit, lint, end to end on kind, publish on tag |
| `test/` | Unit tests for the input validation (`yarn test`) |
| `docs/decisions/` | Architecture decision records (0001: TypeORM 0.3, 0002: authenticating writes, 0003: HTTPS at the ingress, 0004: database availability); `docs/GKE.md` maps the local setup to GKE |
| `docs/ARCHITECTURE.md` | Diagrams (Mermaid): runtime, a request through the ingress, commit to cluster, draining a node, GKE target |
| `docs/RUNBOOK.md` | What to check and do when something fails: symptom, check, cause, fix, verify |
| `docs/PROMQL.md` | The PromQL behind the alerts and the dashboard, explained one query at a time |

## Image

Public image: `ghcr.io/szykman/posts-api:0.3.2`

```bash
scripts/build.sh             # build ghcr.io/szykman/posts-api:<appVersion>
scripts/build.sh --push      # publish it (needs `docker login ghcr.io`)
```

The tag is fixed on purpose (never `latest`) so a running version is always identifiable and a
rollback is just the previous tag.

`build.sh` takes the tag from `appVersion` in `helm/posts-api/Chart.yaml`, so the chart and the
image cannot drift apart. Publishing refuses a working tree with uncommitted changes and refuses
to overwrite a tag that already exists in the registry. The image carries OCI labels (version,
revision, source).

### Continuous integration

`.github/workflows/ci.yml` runs on pull requests, on `main` and on version tags:

| Job | What it does |
|---|---|
| `test` | `yarn test` and `yarn audit` of the runtime dependencies (fails on high severity) |
| `lint` | hadolint on the Dockerfile, `helm lint` (also with the monitoring objects switched on), shellcheck on the scripts |
| `e2e` | `scripts/bootstrap.sh up` and `test` on a kind cluster, the same path a reviewer uses |
| `scan` | Builds the image and scans it with Trivy (operating-system packages and Node dependencies); fails on a CRITICAL or HIGH finding that has a fix available |
| `terraform` | `terraform validate` on the GCP sketch (syntax and references only; nothing is planned or applied) |
| `publish` | Only for a `v*` tag: checks that the tag equals the chart `appVersion`, then runs `build.sh --push` with the workflow token |

Permissions are read-only except in `publish`, which alone can write packages. Releasing is:
bump `appVersion` and `version` in `Chart.yaml`, commit, then `git tag v<appVersion> && git push --tags`.

## What `bootstrap.sh up` does

<details>
<summary>The equivalent manual steps</summary>

```bash
# 1. Cluster (1 control-plane + 3 workers, one per simulated zone)
kind create cluster --config kind/cluster.yaml
kubectl wait --for=condition=Ready node --all --timeout=180s

# 2. Ingress controller (chart version pinned)
helm repo add traefik https://traefik.github.io/charts && helm repo update
helm upgrade --install traefik traefik/traefik --version 41.7.1 \
  -n traefik --create-namespace -f k8s/traefik-values.yaml --wait --timeout 300s

# 3. Namespace and database credentials (generated now, never committed)
kubectl create namespace posts
kubectl -n posts create secret generic posts-db-credentials \
  --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=MYSQL_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=MYSQL_USER=posts \
  --from-literal=MYSQL_DATABASE=posts

# 3b. API token and the ingress certificate (self-signed, one year; the host name is a subjectAltName)
kubectl -n posts create secret generic posts-api-token --from-literal=API_TOKEN="$(openssl rand -hex 32)"
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout tls.key -out tls.crt \
  -subj "/CN=posts.local" -addext "subjectAltName=DNS:posts.local"
kubectl -n posts create secret tls posts-api-tls --cert=tls.crt --key=tls.key && rm tls.key

# 4. The application (database, migration, API, ingress rule)
helm lint helm/posts-api
helm upgrade --install posts-api helm/posts-api -n posts --wait --timeout 300s
```

The script keeps an existing Secret instead of regenerating it: a new password would not
change the one the database was already initialized with.

</details>

### Using an external database

```bash
helm upgrade --install posts-api helm/posts-api -n posts \
  --set mariadb.enabled=false --set database.host=my-db.example.com \
  --set 'migration.hook=pre-install\,pre-upgrade'
```

The Secret then needs `MYSQL_USER`, `MYSQL_PASSWORD` and `MYSQL_DATABASE` only.

## Observability

The API counts its requests and times them, per route pattern and status code, and exposes them with the Node.js
process metrics at `/metrics`. The endpoint lives on its own port (9100) that the Service and the Ingress do not
publish, so it is reachable from inside the cluster only: Prometheus scrapes the pods, nobody else can read it
(the smoke test checks that the ingress answers 404 for it). Labels use the route pattern (`/posts/:id`), never the
URL, so the number of time series stays bounded. The probes are not counted.

The chart carries the rest, off by default so that it installs on a cluster that has no Prometheus Operator:

| Object | Values key | What it does |
|---|---|---|
| `PodMonitor` | `metrics.podMonitor.enabled` | Tells Prometheus to scrape the metrics port of the API pods |
| `PrometheusRule` | `metrics.prometheusRule.enabled` | Five alerts, each linking to its entry in [docs/RUNBOOK.md](docs/RUNBOOK.md) |
| Grafana dashboard | `metrics.grafanaDashboard.enabled` | `dashboards/posts-api.json` in a ConfigMap that Grafana's sidecar loads: request rate, errors, latency percentiles, replicas, memory, event loop lag |

| Alert | Fires when | Severity |
|---|---|---|
| `PostsApiNoReplicasAvailable` | No API replica is ready for 1 minute | critical |
| `PostsApiReplicasUnavailable` | Fewer replicas available than wanted for 5 minutes (a drain does not trip it) | warning |
| `PostsApiHighErrorRate` | More than 5% of the requests answer 5xx for 5 minutes | critical |
| `PostsApiSlowRequests` | The 95th percentile is above 1 second for 10 minutes | warning |
| `PostsApiPodRestarting` | A container restarted more than 3 times in 15 minutes | warning |

```bash
scripts/observability.sh up        # kube-prometheus-stack (pinned, about 1 GB) and the three objects above
scripts/observability.sh test      # Prometheus scrapes every pod, has the metrics and the alerts, none is firing
scripts/observability.sh grafana   # how to open Grafana
scripts/observability.sh down
```

The queries behind the alerts and the dashboard are explained in [docs/PROMQL.md](docs/PROMQL.md).

Thresholds are a starting point to tune against real traffic. Alertmanager is not installed locally, so alerts are
evaluated and visible in Prometheus but nobody is notified; routing them to a person is the missing piece.

## Tests

| Test | What it checks | How |
|---|---|---|
| Unit tests | Input validation: the id whitelist, limits, unknown fields, malformed ids (11 cases; checked by mutation). Authentication: token loading, header parsing, the middleware through a real HTTP server (7 cases). Metrics: counted by route pattern, bounded labels, probes left out, the metrics server (7 cases; checked by mutation) | `yarn test` |
| `helm test` | The API answers `/ready` through its Service, from inside the cluster | Part of the chart |
| Functional smoke test | HTTPS validates against the ingress certificate and plain HTTP is not served; the API pods cover all the zones; a POST without a token and with a wrong token answers 401; with the token, creation answers 201; a POST carrying an `id` is rejected (400) and the existing post stays untouched; a malformed id gives 400; an unknown host gives 404; the pod serves `/metrics` on its own port and the ingress answers 404 for it; all through the ingress | `scripts/bootstrap.sh test` |
| Resilience test | A worker is drained while requests flow through the ingress | `scripts/bootstrap.sh test --resilience` |
| Backup/restore test | A post is created, the database is dumped, the post is deleted (404), the dump is restored and the post is back | `scripts/bootstrap.sh test --backup` |
| Private registry demo | A private image cannot be pulled without the pull Secret and runs with it (needs a private image and a read-only token, see below). Run once on the test host: passed | `scripts/private-registry-demo.sh` |
| Upgrade/rollback test | The release is upgraded, rolled back and upgraded again while requests flow through the ingress | `scripts/bootstrap.sh test --upgrade` |

The smoke test was written to fail on the vulnerable image: against `0.1.0` it stops at
`POST /posts answered 200, expected 201`, and against `0.1.1` all checks pass.

**Resilience results.** Three runs, each draining a different worker, so every zone was covered
(the script picks a node that hosts an API pod but not the database):

| Drained node | Requests | Failed | Evicted pod |
|---|---|---|---|
| `posts-worker2` (zone-b) | 120 | 0 | `Pending`, then `Running` about 26 s after uncordon |
| `posts-worker` (zone-a) | 124 | 0 | `Pending`, then `Running` about 26 s after uncordon |
| `posts-worker3` (zone-c) | 120 | 0 | `Pending`, then `Running` about 25 s after uncordon |

The evicted pod stays `Pending` on purpose: with `whenUnsatisfiable: DoNotSchedule` and
`maxSkew: 1`, placing it in another zone would put two replicas in one zone. The API keeps
serving with two replicas until the node returns. The alternative, `ScheduleAnyway`, would
recover capacity immediately but give up the one-replica-per-zone guarantee while the node is
away.

**Upgrade and rollback results.** Two runs, with requests flowing the whole time.

*Run 1, `0.1.0` to `0.1.1`* (validation fix; no schema change):

| Phase | Requests | Failed |
|---|---|---|
| Upgrade (revision 1 to 2) | 92 | 0 |
| Rollback (to revision 1, recorded as revision 3) | 48 | 0 |
| Upgrade again (revision 4) | 69 | 0 |

*Run 2, `0.1.1` to `0.2.0`* (TypeORM 0.3.31, from revision 4):

| Phase | Requests | Failed |
|---|---|---|
| Upgrade (revision 5) | 97 | 0 |
| Rollback (to revision 4, recorded as revision 6) | 39 | 0 |
| Upgrade again (revision 7) | 54 | 0 |

190 requests in total, none failed. After the upgrade the pods report TypeORM `0.3.31`, and the
migration Job (new `-d src/data-source.js` command) logged `No migrations are pending` against a
database created by TypeORM 0.2. The rollback pods became Ready and served traffic; reading and
writing the same data from 0.2 and 0.3 was verified outside the cluster only, on a test database.

In both runs the `pre-upgrade` hook created a new migration Job on each upgrade and did not run on the
rollback. That is expected: a rollback does not run the migration hook and does not revert the schema,
so it is only safe while schema changes stay backward compatible. Neither upgrade changed the schema.

**What these tests do not prove.** The resilience runs last about 25 seconds and the upgrade run
about a minute, at roughly five requests per second, and they only call `/ready`. They show
availability while a node is lost and while a version changes; they are not load tests, and a
failure shorter than 200 ms could go unnoticed.

## Database backup and restore

```bash
scripts/db.sh backup                  # backups/posts-<UTC>.sql (mode 600, ignored by Git)
scripts/db.sh restore backups/<file>  # asks you to type "restore" first
```

The restore is tested end to end by `scripts/bootstrap.sh test --backup`. A backup bounds data loss; it does not
make the database highly available. What high availability would take (a managed database with a standby in another
zone, or an operator-managed MariaDB), and what is deliberately not built, is in
[`docs/decisions/0004-database-availability.md`](docs/decisions/0004-database-availability.md).

## Private registry

The published image is public on purpose, so an evaluator can run everything without credentials. A private
registry changes one thing: the node must authenticate to pull. Kubernetes does that with an *image pull
Secret* named in `imagePullSecrets`, which the chart already puts in the Deployment, the migration Job and the test pod.

```bash
# the token only needs to READ packages (for ghcr.io: a token with the read:packages scope)
REGISTRY_USER=<user> scripts/create-pull-secret.sh regcred        # asks for the token without echoing it
helm upgrade --install posts-api helm/posts-api -n posts --reuse-values --set 'imagePullSecrets[0].name=regcred'
```

Without the Secret the pod stays in `ErrImagePull` / `ImagePullBackOff` and the event says `unauthorized`.
`scripts/private-registry-demo.sh` shows both sides with a throw-away pod:

```bash
PRIVATE_IMAGE=ghcr.io/<user>/<private-package>:<tag> REGISTRY_USER=<user> REGISTRY_TOKEN=<token> scripts/private-registry-demo.sh
```

**Run on the test host (12 October 2026).** A private copy of the published image (`ghcr.io/szykman/posts-api-private:0.3.1`, same
digest as the public `0.3.1`) was made and its visibility set to private. Without credentials the registry answered
`unauthorized` to a pull. In the cluster, the pod without the Secret stayed in `ErrImagePull` (the event shows the registry
answering `401 Unauthorized` to the anonymous token request), and the same image started and ran with a Secret built from a
token that had only the `read:packages` scope. The script ended with `Private registry demo passed`. The tokens were revoked afterwards.

Points to know:

- **Check that the image is really private.** A GHCR package connected to a public repository can inherit public
  visibility. The demo fails with "the pod ran without credentials" if it is not private.
- The demo image needs a `sleep` binary (the application image has one).
- The token is stored in a Secret, which is only base64, not encrypted; use a read-only, short-lived token.
- On GKE nodes pull from Artifact Registry in the same project with the node service account's
  permissions, so no pull Secret is needed there; the Secret is the answer for a registry outside the cloud.

## Design decisions

| Decision | Why |
|---|---|
| Three replicas with `topologySpreadConstraints` (zone, `maxSkew: 1`, `DoNotSchedule`, `matchLabelKeys: [pod-template-hash]`) | `replicas: 3` alone could place every pod in one zone. The constraint forces one pod per zone, so losing a zone loses at most one replica. `matchLabelKeys` makes a rolling update balance the new pods on their own; without it the old pods are counted and the new ones can end up uneven (seen once, see the build notes). Needs Kubernetes 1.27 or newer. |
| PodDisruptionBudget `maxUnavailable: 1` | A voluntary disruption (node drain) can take down at most one pod at a time. Unlike `minAvailable: 2`, it keeps working if the replica count changes. |
| Separate `/health` and `/ready` | Liveness does not touch the database: if the database is down, restarting the app would not help. Readiness checks the database, so a pod without a database leaves the Service instead of being restarted. |
| Rolling update with `maxUnavailable: 0`, `preStop` sleep and graceful shutdown | The app handles SIGTERM, stops accepting connections, finishes in-flight requests and closes the pool. The `preStop` delay gives the endpoint removal time to propagate. |
| Migrations as a Helm hook (`post-install,pre-upgrade`), not at app start | Three replicas starting together would race to change the schema. On first install the bundled database is part of the same release and does not exist during `pre-install`, hence `post-install`; on upgrades the schema changes before new pods roll out. |
| `wait-for-db` init container (bounded) on the API and the migration Job | Avoids crash loops when the database and the API start at the same time. |
| `values.schema.json` rejects unknown keys | A misspelled or unsupported value fails at install time instead of being silently ignored. |
| `TYPEORM_SYNCHRONIZE=false` plus an initial migration | The ORM must not alter a production schema on its own. |
| HTTPS only, with a self-signed certificate generated by `up` | The Bearer token is worthless on a clear-text link. The ingress serves the host on the HTTPS entrypoint only, so plain HTTP answers 404 instead of working unencrypted; tests verify the certificate with `--cacert`, never `-k`. In a cloud cluster the same Ingress takes a cert-manager certificate. See `docs/decisions/0003-https-at-the-ingress.md`. |
| Writes need a Bearer token, and the API will not start without one | The producers are unknown, so the API is assumed reachable from the internet. Fail closed, with no switch to turn it off; reads stay public. One shared token is the proportionate minimum and has known limits. See `docs/decisions/0002-authenticate-writes.md`. |
| TypeORM 0.3.31 with a single `DataSource` file | 0.2.x carried 4 advisories (24 audit findings in total, all in TypeORM and its dependencies); 0.3.31 clears them. The migration CLI needs the DataSource file, so the app, the health check and the migration Job share one connection definition. See `docs/decisions/0001-typeorm-0.3.md`. |
| Request bodies are whitelisted and validated by hand; unknown fields are rejected | `save()` updates the row when the entity carries a primary key, so a client-supplied `id` overwrote an existing post (reproduced before the fix). Rejecting instead of ignoring makes the failure visible. No validation library: two small entities do not justify the extra dependency. |
| npm is removed from the runtime image | The container only runs `node`. The first Trivy scan reported 10 HIGH findings, all in libraries bundled inside npm (the application's own dependencies were clean); deleting npm removes them and a tool nobody needs at runtime. |
| Multi-stage Dockerfile, numeric user `1000:1000`, exec-form `CMD` | No compiler or dev tooling in the runtime image; Kubernetes can verify `runAsNonRoot` only with a numeric user; Node is PID 1 and receives SIGTERM directly. |
| Pod hardening | Read-only root filesystem, all capabilities dropped, no privilege escalation, `seccomp: RuntimeDefault`, no service account token mounted, resource requests and limits. |
| Credentials in a Secret, outside Git and outside the image | `ormconfig.env` is excluded from the build context; connection settings arrive as `TYPEORM_*` environment variables. |
| Traefik instead of ingress-nginx | ingress-nginx was retired in March 2026 and no longer receives security fixes. The Gateway API is the natural evolution. |
| Traefik with `hostPort` on the control-plane node | kind has no `LoadBalancer`. In a cloud cluster the ingress would sit behind a multi-zone load balancer. |
| Host ports 18080/18443 bound to 127.0.0.1 | Common ports 8080/8443 were already in use on the test machine; nothing is exposed beyond loopback. |
| Scripts always pass an explicit kube context | A drain or install must never reach a cluster other than the local one. |
| The resilience test refuses to drain the database node | The bundled database is a single instance with a node-bound volume; draining its node takes the API down. The scheduler decides where the database lands, so the test picks the node at run time. |

## Notes from the build

- The Traefik chart accepted `service.type` without complaint and ignored it (this chart version
  uses `service.spec.type`). The Service stayed `LoadBalancer`, `helm --wait` timed out, and
  `helm get values` plus `helm show values` for the pinned version found the cause. This is why
  our own chart ships a values schema.
- A `POST /posts` carrying `"id":1` overwrote an existing post. The problem was reproduced first, then
  fixed in the application (upgrading TypeORM would not have fixed it: it is how `save()` works).
  The image was rebuilt as `0.1.1` and rolled out with the upgrade test.
- The TypeORM upgrade (`0.2.38` to `0.3.31`) was measured on a throwaway copy before deciding, then
  shipped as image `0.2.0` and rolled out with the same upgrade test (digest in the ADR).
- The first real upgrade (`0.2.0` to `0.3.0`) left the three API pods in two zones (two in zone-c, none in zone-b)
  although `maxSkew` is 1: during a rolling update the selector counted the old pods as well. A fresh install
  never shows this, so CI did not catch it. The fix is `matchLabelKeys: [pod-template-hash]` (chart `0.3.1`, same
  image), and `bootstrap.sh test` now checks that the API pods cover the zones.
- The first resilience run refused to start because the scheduler had put the database on the
  node the script drained by default. The default is now chosen at run time.

## Changes to the original application

- Declared `reflect-metadata` (it was only available transitively); refreshed Express and body-parser within the semver ranges already allowed (`yarn audit`: 46 findings down to 24, then to 0 for runtime dependencies after the TypeORM upgrade).
- Added `GET /health` and `GET /ready`; the port is configurable through `PORT`.
- Graceful shutdown on SIGTERM/SIGINT; the process now exits with code 1 when the database is unreachable at start-up (it used to exit with 0, hiding the failure).
- Central error handler (no stack traces to clients), `x-powered-by` removed, fixed the route wrapper that returned `next` instead of calling it.
- `POST /posts` accepts only `title`, `text` and `categories[].name` (rejects the rest with 400, answers 201 on creation); `GET /posts/:id` accepts only a positive integer. Hand-written validation in `src/validation.ts`, with unit tests.
- `POST /posts` requires `Authorization: Bearer <API_TOKEN>` (`src/auth.ts`); the API refuses to start without `API_TOKEN`.
- Upgraded TypeORM to 0.3.31 (TypeScript 3.9 to 5.9, `@types/node` 9 to 22, `mysql` to `mysql2`; `ts-node-dev` removed, `dotenv` added). Connection settings live in `src/data-source.ts`.
- Added the initial migration and the `build`, `start:prod`, `migration:run`, `migration:revert` and `migration:generate` scripts; the migration commands use `-d src/data-source.js` and run from compiled JavaScript with runtime dependencies only.

## Verified on

A Linux host with Docker, kind v0.33.0 (node image Kubernetes v1.37.0), kubectl v1.37.1,
Helm v3.22.0, Traefik chart 41.7.1 (Traefik v3.7.14), MariaDB 10.11, Node 22 for the image build,
TypeORM 0.3.31, TypeScript 5.9, mysql2.
Not tested on macOS or Windows.

**Published image, `0.3.1`.** The release was upgraded on the test host from the registry (no local build): the three API
pods and the migration Job report the digest `sha256:6538cc52ff0e56af943edd22cc8b135c362e4b5954b63ed947cb5b4fe0355ce0`
(the one printed by the publish job), the 12 smoke checks passed, and the backup/restore test passed. The three API pods
were spread over the three zones.

**Observability (22 October 2026, image built from the checkout).** `bootstrap.sh up` and `bootstrap.sh test` passed, including
the two metrics checks (the pod serves `/metrics` on port 9100; the ingress answers 404). `observability.sh up` and `test`
passed on the same cluster: all three API pods are Prometheus targets and up, `http_requests_total` has samples for
`GET /posts`, the five alerts are loaded and none fires. The dashboard file `posts-api.json` was loaded by the Grafana
sidecar. The panels were not inspected in a browser.

**Published image, `0.3.2` (22 October 2026).** After `docker logout ghcr.io` the image was pulled without credentials
(digest `sha256:224670bc27de3c5fe5013d49e41bb86e7433100ccce05f33ea0f0ed7776cbc79`). The release was then upgraded on the
test host from the registry (no local build): the three API pods and the migration Job report that digest, and the 14
smoke checks passed, including the two for `/metrics`.

## Known limitations

- **The database is a single instance.** Its volume is bound to the node where it was created. The API is highly available; the database is not. A tested backup and restore exist; the options for real HA (managed database, operator) and their trade-offs are in ADR 0004. No scheduled or off-cluster backup is built.
- **The ingress controller runs one replica** on the control-plane node, which is a single point of failure locally.
- **Zones are simulated** with node labels. The scheduling logic is the same as on real zones, but no real failure domain exists.
- **The certificate is self-signed.** Browsers warn about it and clients need `--cacert`; it expires after a year and is renewed by deleting the Secret `posts-api-tls` and running `up`. Traffic behind the ingress (to the pods and to the database) is not encrypted.
- **TypeORM:** `yarn audit` reports 0 findings for the runtime dependencies. The image itself is scanned by Trivy in CI (fixable CRITICAL and HIGH findings fail the build); development dependencies are not part of the image. The migration command in the chart needs an image `>= 0.2.0`. TypeORM 1.x was only probed (it compiled and ran), not adopted.
- **Authentication is one shared token, for writes only.** It cannot tell producers apart or be revoked for one of them, there is no rate limit, and anyone who can reach the ingress can still read every post. See the ADR for when to move to per-client credentials.
- `/ready` checks connectivity only, not whether migrations were applied.
- The image is `amd64` only. The base image is pinned by digest (see the Dockerfile), so it only changes when someone updates it on purpose.
- Not yet exercised: load, and an upgrade that changes the database schema.

## Roadmap

1. Evaluate TypeORM 1.x once it has had more time in the field.
2. Pin the GitHub Actions to commit SHAs, scan the image itself (not only `yarn audit`) and sign it.
3. Load test.
4. cert-manager with a real issuer, NetworkPolicy, a rate limit, and per-client credentials if there are several producers.
5. Add Secret Manager with External Secrets, cert-manager and Cloud SQL to the GKE setup (the trial in `docs/GKE.md` used the bundled database and a self-signed certificate).

## Local development (without Kubernetes)

```bash
yarn install
docker run -d -p 127.0.0.1:3306:3306 -e MYSQL_ROOT_PASSWORD=test -e MYSQL_DATABASE=test \
  -e MYSQL_USER=test -e MYSQL_PASSWORD=test mariadb:10.11
yarn build
yarn migration:run
yarn start:prod        # http://localhost:3000/posts
```

`TYPEORM_*` environment variables take precedence over `ormconfig.env`, which is read for local
development only. The same file holds a development `API_TOKEN`; writes need it:
`curl -H "Authorization: Bearer dev-token-change-me-0123456789" -H 'content-type: application/json' -d '{"title":"t","text":"x"}' localhost:3000/posts`. `yarn migration:generate` creates a migration from entity changes.

`ormconfig.env` holds local development defaults only.
