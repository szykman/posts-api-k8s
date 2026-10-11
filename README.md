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

```bash
scripts/bootstrap.sh up                  # cluster + ingress + secret + application
scripts/bootstrap.sh test                # helm test + functional smoke test
scripts/bootstrap.sh test --resilience   # ...plus the node-drain resilience test
scripts/bootstrap.sh test --upgrade      # ...plus the upgrade/rollback test (changes the release revision)
scripts/bootstrap.sh down                # delete everything
```

`up` is idempotent (safe to re-run). Measured on a Linux host with 8 CPUs and 15 GiB of RAM,
with the kind node image already pulled, a full `up` from nothing took about 1 min 20 s
(two measurements: 1 min 18 s and 1 min 22 s).
The very first run also downloads images and takes longer.

Every `kubectl`/`helm` call in the scripts targets the `kind-posts` context explicitly, so the
scripts cannot act on whatever cluster happens to be your current context.

After `up`:

```bash
curl -H "Host: posts.local" http://localhost:18080/posts
```

## Requirements checklist

| Requirement | Status | Where |
|---|---|---|
| 1. Image published in a public registry | Done | `ghcr.io/szykman/posts-api:0.1.1` (public, pulled without credentials) |
| 2. Code to deploy it to Kubernetes | Done | `helm/posts-api/` |
| 3. Exposed outside the cluster | Done | Traefik ingress, routing `posts.local` |
| 4. Highly available across 3 zones | Done | 3 replicas, `topologySpreadConstraints`, PodDisruptionBudget, probes; see [Tests](#tests) |
| Optional: reverse proxy instead of exposing the service | Done | Traefik |
| Optional: Helm | Done | `helm/posts-api/` |
| Optional: 2+ worker nodes | Done | 3 workers, one per simulated zone |
| Optional: script that builds the cluster, deploys and tests | Done | `scripts/bootstrap.sh` |
| Optional: test scenarios | Partly | Unit, smoke/functional, resilience and upgrade/rollback tests; no load test yet |
| Optional: script that builds the image | Not yet | The image is built with `docker build` (see below) |
| Optional: private registry authentication | Not yet | The chart already accepts `imagePullSecrets` |
| Optional: Terraform, remote cloud environment | Not done | See the roadmap |

## Architecture

```
        127.0.0.1:18080  (kind port mapping, loopback only)
                |
        Traefik ingress controller   (control-plane node, hostPort 80)
                |   Host: posts.local
        Service posts-api  (ClusterIP)
        +-------+-------+
   Pod zone-a   Pod zone-b   Pod zone-c      <- topologySpreadConstraints
        +-------+-------+
        Service posts-api-db   (ClusterIP, not reachable from outside)
                |
        StatefulSet posts-api-db-0   (MariaDB 10.11, 1Gi PVC)
```

| Path | Purpose |
|---|---|
| `src/` | Application (TypeScript) and the initial TypeORM migration |
| `Dockerfile`, `.dockerignore` | Multi-stage image build |
| `kind/cluster.yaml` | Local cluster: 1 control-plane + 3 workers labelled `zone-a/b/c` |
| `helm/posts-api/` | Helm chart: API, Service, PodDisruptionBudget, Ingress, migration hook, optional MariaDB, `helm test` |
| `k8s/traefik-values.yaml` | Helm values for the Traefik ingress controller |
| `scripts/bootstrap.sh` | `up`, `test`, `down` |
| `scripts/resilience-test.sh` | Drains a worker under traffic and counts failed requests |
| `scripts/upgrade-test.sh` | Upgrades, rolls back and upgrades the release under traffic |
| `test/` | Unit tests for the input validation (`yarn test`) |

## Image

Public image: `ghcr.io/szykman/posts-api:0.1.1`

```bash
docker build -t ghcr.io/szykman/posts-api:0.1.1 .
docker push ghcr.io/szykman/posts-api:0.1.1     # needs `docker login ghcr.io`
```

The tag is fixed on purpose (never `latest`) so a running version is always identifiable and a
rollback is just the previous tag.

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

## Tests

| Test | What it checks | How |
|---|---|---|
| Unit tests | Input validation: the id whitelist, limits, unknown fields, malformed ids (11 cases; checked by mutation) | `yarn test` |
| `helm test` | The API answers `/ready` through its Service, from inside the cluster | Part of the chart |
| Functional smoke test | Creation answers 201; a POST carrying an `id` is rejected (400) and the existing post stays untouched; a malformed id gives 400; an unknown host gives 404; all through the ingress | `scripts/bootstrap.sh test` |
| Resilience test | A worker is drained while requests flow through the ingress | `scripts/bootstrap.sh test --resilience` |
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

**Upgrade and rollback results.** One run, from `0.1.0` to `0.1.1`, with requests flowing the whole time:

| Phase | Requests | Failed |
|---|---|---|
| Upgrade (revision 1 to 2) | 92 | 0 |
| Rollback (to revision 1, recorded as revision 3) | 48 | 0 |
| Upgrade again (revision 4) | 69 | 0 |

The `pre-upgrade` hook created a new migration Job on the upgrade and did not run on the rollback.
That is expected: a rollback does not run the migration hook and does not revert the schema, so it
is only safe while schema changes stay backward compatible. This upgrade changed no schema.

**What these tests do not prove.** The resilience runs last about 25 seconds and the upgrade run
about a minute, at roughly five requests per second, and they only call `/ready`. They show
availability while a node is lost and while a version changes; they are not load tests, and a
failure shorter than 200 ms could go unnoticed.

## Design decisions

| Decision | Why |
|---|---|
| Three replicas with `topologySpreadConstraints` (zone, `maxSkew: 1`, `DoNotSchedule`) | `replicas: 3` alone could place every pod in one zone. The constraint forces one pod per zone, so losing a zone loses at most one replica. |
| PodDisruptionBudget `maxUnavailable: 1` | A voluntary disruption (node drain) can take down at most one pod at a time. Unlike `minAvailable: 2`, it keeps working if the replica count changes. |
| Separate `/health` and `/ready` | Liveness does not touch the database: if the database is down, restarting the app would not help. Readiness checks the database, so a pod without a database leaves the Service instead of being restarted. |
| Rolling update with `maxUnavailable: 0`, `preStop` sleep and graceful shutdown | The app handles SIGTERM, stops accepting connections, finishes in-flight requests and closes the pool. The `preStop` delay gives the endpoint removal time to propagate. |
| Migrations as a Helm hook (`post-install,pre-upgrade`), not at app start | Three replicas starting together would race to change the schema. On first install the bundled database is part of the same release and does not exist during `pre-install`, hence `post-install`; on upgrades the schema changes before new pods roll out. |
| `wait-for-db` init container (bounded) on the API and the migration Job | Avoids crash loops when the database and the API start at the same time. |
| `values.schema.json` rejects unknown keys | A misspelled or unsupported value fails at install time instead of being silently ignored. |
| `TYPEORM_SYNCHRONIZE=false` plus an initial migration | The ORM must not alter a production schema on its own. |
| Request bodies are whitelisted and validated by hand; unknown fields are rejected | `save()` updates the row when the entity carries a primary key, so a client-supplied `id` overwrote an existing post (reproduced before the fix). Rejecting instead of ignoring makes the failure visible. No validation library: two small entities do not justify the extra dependency. |
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
- The first resilience run refused to start because the scheduler had put the database on the
  node the script drained by default. The default is now chosen at run time.

## Changes to the original application

- Declared `reflect-metadata` (it was only available transitively); refreshed Express and body-parser within the semver ranges already allowed (`yarn audit`: 46 findings down to 24).
- Added `GET /health` and `GET /ready`; the port is configurable through `PORT`.
- Graceful shutdown on SIGTERM/SIGINT; the process now exits with code 1 when the database is unreachable at start-up (it used to exit with 0, hiding the failure).
- Central error handler (no stack traces to clients), `x-powered-by` removed, fixed the route wrapper that returned `next` instead of calling it.
- `POST /posts` accepts only `title`, `text` and `categories[].name` (rejects the rest with 400, answers 201 on creation); `GET /posts/:id` accepts only a positive integer. Hand-written validation in `src/validation.ts`, with unit tests.
- Added the initial migration and the `build`, `start:prod`, `migration:run` and `migration:revert` scripts, which run from compiled JavaScript with runtime dependencies only.

## Verified on

A Linux host with Docker, kind v0.33.0 (node image Kubernetes v1.37.0), kubectl v1.37.1,
Helm v3.22.0, Traefik chart 41.7.1 (Traefik v3.7.14), MariaDB 10.11, Node 22 for the image build.
Not tested on macOS or Windows.

## Known limitations

- **The database is a single instance.** Its volume is bound to the node where it was created. The API is highly available; the database is not. In production this would be a managed database or a replicated setup.
- **The ingress controller runs one replica** on the control-plane node, which is a single point of failure locally.
- **Zones are simulated** with node labels. The scheduling logic is the same as on real zones, but no real failure domain exists.
- **No TLS** is configured yet.
- **TypeORM 0.2.x** has known advisories (a fix requires 0.3, which changes the API); 24 audit findings remain, all in TypeORM and its dependencies. The critical SQL injection advisory (CVE-2022-33171) concerns `findOne` receiving a user-controlled object; the only `findOne` here receives an integer validated by `parseId`, so it is not reachable from this code. Scanners will still report it.
- **No authentication or authorization:** anyone who can reach the ingress can read and create posts.
- `/ready` checks connectivity only, not whether migrations were applied.
- The image is `amd64` only and its base tag is not pinned by digest.
- Not yet exercised: load, and an upgrade that changes the database schema.

## Roadmap

1. A decision on TypeORM 0.3.
2. CI (build, vulnerability scan, push) and an image build script.
3. Load test.
4. NetworkPolicy, TLS and authentication.
5. Terraform for the cluster and ingress, keeping Helm for the application.

## Local development (without Kubernetes)

```bash
yarn install
docker run -d -p 127.0.0.1:3306:3306 -e MYSQL_ROOT_PASSWORD=test -e MYSQL_DATABASE=test \
  -e MYSQL_USER=test -e MYSQL_PASSWORD=test mariadb:10.11
yarn build
yarn migration:run
yarn start:prod        # http://localhost:3000/posts
```

`ormconfig.env` holds local development defaults only.
