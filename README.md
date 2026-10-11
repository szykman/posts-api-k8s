# posts-api on Kubernetes

A small Express + TypeORM REST API ("posts"), containerized and deployed to a
local multi-node Kubernetes cluster (kind) in a highly available layout: three
replicas spread across three (simulated) availability zones, behind an ingress.
The deployment is packaged as a Helm chart.

The original challenge statement is kept in [docs/CHALLENGE.md](docs/CHALLENGE.md).

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

## Image

Public image: `ghcr.io/szykman/posts-api:0.1.0`

```bash
docker build -t ghcr.io/szykman/posts-api:0.1.0 .
```

The tag is fixed on purpose (never `latest`) so a running version is always
identifiable and a rollback is just the previous tag.

## Run it from scratch

Prerequisites: Docker, [kind](https://kind.sigs.k8s.io/), `kubectl`, [Helm 3](https://helm.sh/).
Host ports 18080 and 18443 must be free (change them in `kind/cluster.yaml` otherwise).

```bash
# 1. Cluster (1 control-plane + 3 workers, one per simulated zone)
kind create cluster --config kind/cluster.yaml
kubectl get nodes -L topology.kubernetes.io/zone

# 2. Ingress controller (chart version pinned)
helm repo add traefik https://traefik.github.io/charts && helm repo update
helm upgrade --install traefik traefik/traefik --version 41.7.1 \
  -n traefik --create-namespace -f k8s/traefik-values.yaml --wait --timeout 300s

# 3. Namespace and database credentials.
#    The Secret is generated at install time and is never committed.
kubectl create namespace posts
kubectl -n posts create secret generic posts-db-credentials \
  --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=MYSQL_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=MYSQL_USER=posts \
  --from-literal=MYSQL_DATABASE=posts

# 4. The application (database, migration, API, ingress rule)
helm lint helm/posts-api
helm upgrade --install posts-api helm/posts-api -n posts --wait --timeout 300s
kubectl -n posts get pods -o wide        # one API pod per worker

# 5. Smoke test and manual check
helm -n posts test posts-api
curl -H "Host: posts.local" localhost:18080/ready
curl -X POST -H "Host: posts.local" -H "content-type: application/json" \
  -d '{"title":"hello","text":"from kubernetes"}' localhost:18080/posts
curl -H "Host: posts.local" localhost:18080/posts
```

Tear down: `kind delete cluster --name posts`.

### Using an external database

```bash
helm upgrade --install posts-api helm/posts-api -n posts \
  --set mariadb.enabled=false --set database.host=my-db.example.com \
  --set 'migration.hook=pre-install\,pre-upgrade'
```

The Secret then needs `MYSQL_USER`, `MYSQL_PASSWORD` and `MYSQL_DATABASE` only.

## Design decisions

| Decision | Why |
|---|---|
| Three replicas with `topologySpreadConstraints` (zone, `maxSkew: 1`, `DoNotSchedule`) | `replicas: 3` alone could place every pod in one zone. The constraint forces one pod per zone, so losing a zone loses at most one replica. |
| PodDisruptionBudget `maxUnavailable: 1` | A voluntary disruption (node drain) can take down at most one pod at a time. Unlike `minAvailable: 2`, it keeps working if the replica count changes. |
| Separate `/health` and `/ready` | Liveness does not touch the database: if the database is down, restarting the app would not help. Readiness checks the database, so a pod without a database leaves the Service instead of being restarted. |
| Rolling update with `maxUnavailable: 0`, `preStop` sleep and graceful shutdown | The app handles SIGTERM, stops accepting connections, finishes in-flight requests and closes the pool. The `preStop` delay gives the endpoint removal time to propagate. |
| Migrations as a Helm hook (`post-install,pre-upgrade`), not at app start | Three replicas starting together would race to change the schema. On first install the bundled database is part of the same release and does not exist during `pre-install`, hence `post-install`; on upgrades the schema changes before new pods roll out. |
| `wait-for-db` init container (bounded) on the API and the migration Job | Avoids crash loops when the database and the API start at the same time. |
| `values.schema.json` rejects unknown keys | A misspelled or unsupported value fails at install time instead of being silently ignored. This was learned the hard way with the Traefik chart, where `service.type` was accepted and ignored. |
| `TYPEORM_SYNCHRONIZE=false` plus an initial migration | The ORM must not alter a production schema on its own. |
| Multi-stage Dockerfile, numeric user `1000:1000`, exec-form `CMD` | No compiler or dev tooling in the runtime image; Kubernetes can verify `runAsNonRoot` only with a numeric user; Node is PID 1 and receives SIGTERM directly. |
| Pod hardening | Read-only root filesystem, all capabilities dropped, no privilege escalation, `seccomp: RuntimeDefault`, no service account token mounted, resource requests and limits. |
| Credentials in a Secret, outside Git and outside the image | `ormconfig.env` is excluded from the build context; connection settings arrive as `TYPEORM_*` environment variables. |
| Traefik instead of ingress-nginx | ingress-nginx was retired in March 2026 and no longer receives security fixes. The Gateway API is the natural evolution. |
| Traefik with `hostPort` on the control-plane node | kind has no `LoadBalancer`. In a cloud cluster the ingress would sit behind a multi-zone load balancer. |
| Host ports 18080/18443 bound to 127.0.0.1 | Common ports 8080/8443 were already in use on the test machine; nothing is exposed beyond loopback. |

## Changes to the original application

- Declared `reflect-metadata` (it was only available transitively); refreshed Express and body-parser within the semver ranges already allowed (`yarn audit`: 46 findings down to 24).
- Added `GET /health` and `GET /ready`; the port is configurable through `PORT`.
- Graceful shutdown on SIGTERM/SIGINT; the process now exits with code 1 when the database is unreachable at start-up (it used to exit with 0, hiding the failure).
- Central error handler (no stack traces to clients), `x-powered-by` removed, fixed the route wrapper that returned `next` instead of calling it.
- Added the initial migration and the `build`, `start:prod`, `migration:run` and `migration:revert` scripts, which run from compiled JavaScript with runtime dependencies only.

## What was verified

- `docker build` succeeds; `docker stop` completes in about 0.25 s with exit code 0; the process runs as uid 1000.
- `helm lint` passes; values that are not in the schema (`replicaCnt`, `service.type`) are rejected.
- A fresh `helm install` brings up the database, three API pods (one per worker, zones a, b and c) and runs the migration hook afterwards; `helm test` succeeds.
- `/ready`, `POST /posts` and `GET /posts` work through the ingress; a request without the expected `Host` header gets a 404.

## Known limitations

- **The database is a single instance.** Its volume is bound to the node where it was created. The API is highly available; the database is not. In production this would be a managed database or a replicated setup.
- **The ingress controller runs one replica** on the control-plane node, which is a single point of failure locally.
- **Zones are simulated** with node labels. The scheduling logic is the same as on real zones, but no real failure domain exists.
- **No TLS** is configured yet.
- **TypeORM 0.2.x** has known advisories (a fix requires 0.3, which changes the API). 24 audit findings remain, all in TypeORM and its dependencies.
- `POST /posts` does not validate or whitelist fields.
- `/ready` checks connectivity only, not whether migrations were applied.
- The image is `amd64` only and its base tag is not pinned by digest.
- Setup is a documented sequence of commands, not yet a single script.
- Not yet exercised: the `pre-upgrade` hook and a rolling update, zone-failure behavior, and load.

## Roadmap

1. One script that creates the cluster, deploys and runs the tests.
2. Resilience test (drain a worker and observe availability) and a light load test.
3. Input validation on `POST /posts` and a decision on TypeORM 0.3.
4. CI (build, vulnerability scan, push), then NetworkPolicy and TLS.

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
