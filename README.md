# posts-api on Kubernetes

A small Express + TypeORM REST API ("posts"), containerized and deployed to a
local multi-node Kubernetes cluster (kind) in a highly available layout: three
replicas spread across three (simulated) availability zones, behind an ingress.

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
        Service posts-db   (ClusterIP, not reachable from outside)
                |
        StatefulSet posts-db-0   (MariaDB 10.11, 1Gi PVC)
```

| Path | Purpose |
|---|---|
| `src/` | Application (TypeScript) and the initial TypeORM migration |
| `Dockerfile`, `.dockerignore` | Multi-stage image build |
| `kind/cluster.yaml` | Local cluster: 1 control-plane + 3 workers labelled `zone-a/b/c` |
| `k8s/mariadb.yaml` | MariaDB StatefulSet + Service |
| `k8s/migration-job.yaml` | Schema migration, run once as a Job |
| `k8s/api.yaml` | API Deployment, Service and PodDisruptionBudget |
| `k8s/traefik-values.yaml` | Helm values for the Traefik ingress controller |
| `k8s/ingress.yaml` | Ingress rule routing `posts.local` to the API |

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

# 2. Namespace and database credentials.
#    The Secret is generated at install time and is never committed.
kubectl create namespace posts
kubectl -n posts create secret generic posts-db-credentials \
  --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=MYSQL_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=MYSQL_USER=posts \
  --from-literal=MYSQL_DATABASE=posts

# 3. Database
kubectl apply -f k8s/mariadb.yaml
kubectl -n posts rollout status statefulset/posts-db --timeout=180s

# 4. Schema migration (a Job that uses the application image)
kubectl apply -f k8s/migration-job.yaml
kubectl -n posts wait --for=condition=complete job/posts-migrate --timeout=180s

# 5. API (3 replicas)
kubectl apply -f k8s/api.yaml
kubectl -n posts rollout status deployment/posts-api --timeout=180s
kubectl -n posts get pods -l app.kubernetes.io/name=posts-api -o wide   # one pod per worker

# 6. Ingress controller (chart version pinned) and routing rule
helm repo add traefik https://traefik.github.io/charts && helm repo update
helm upgrade --install traefik traefik/traefik --version 41.7.1 \
  -n traefik --create-namespace -f k8s/traefik-values.yaml --wait --timeout 300s
kubectl apply -f k8s/ingress.yaml

# 7. Try it
curl -H "Host: posts.local" localhost:18080/ready
curl -X POST -H "Host: posts.local" -H "content-type: application/json" \
  -d '{"title":"hello","text":"from kubernetes"}' localhost:18080/posts
curl -H "Host: posts.local" localhost:18080/posts
```

Tear down: `kind delete cluster --name posts`.

## Design decisions

| Decision | Why |
|---|---|
| Three replicas with `topologySpreadConstraints` (zone, `maxSkew: 1`, `DoNotSchedule`) | `replicas: 3` alone could place every pod in one zone. The constraint forces one pod per zone, so losing a zone loses at most one replica. |
| PodDisruptionBudget `maxUnavailable: 1` | A voluntary disruption (node drain) can take down at most one pod at a time. Unlike `minAvailable: 2`, it keeps working if the replica count changes. |
| Separate `/health` and `/ready` | Liveness does not touch the database: if the database is down, restarting the app would not help. Readiness checks the database, so a pod without a database leaves the Service instead of being restarted. |
| Rolling update with `maxUnavailable: 0`, `preStop` sleep and graceful shutdown | The app handles SIGTERM, stops accepting connections, finishes in-flight requests and closes the pool. The `preStop` delay gives the endpoint removal time to propagate. |
| Migrations as a Job, not at app start | Three replicas starting together would race to change the schema. A Job runs once, explicitly. |
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
- The migration runs inside the cluster from the public image and creates the four tables.
- Three API pods run Ready, one per worker (zone-a, zone-b, zone-c), and the Service has three endpoints.
- `/ready`, `POST /posts` and `GET /posts` work through the Service and through the ingress; a request without the expected `Host` header gets a 404.

## Known limitations

- **The database is a single instance.** Its volume is bound to the node where it was created. The API is highly available; the database is not. In production this would be a managed database or a replicated setup.
- **The ingress controller runs one replica** on the control-plane node, which is a single point of failure locally.
- **Zones are simulated** with node labels. The scheduling logic is the same as on real zones, but no real failure domain exists.
- **No TLS** is configured yet.
- **TypeORM 0.2.x** has known advisories (a fix requires 0.3, which changes the API). 24 audit findings remain, all in TypeORM and its dependencies.
- `POST /posts` does not validate or whitelist fields.
- `/ready` checks connectivity only, not whether migrations were applied.
- The image is `amd64` only and its base tag is not pinned by digest.
- Setup is a documented sequence of commands, not yet a single script. There are no automated tests or CI yet, and zone-failure behavior has not been exercised.

## Roadmap

1. Helm chart for the application (migration as a pre-install/pre-upgrade hook).
2. One script that creates the cluster, deploys and runs the smoke tests.
3. Smoke and load tests, including draining a worker to observe availability.
4. Input validation on `POST /posts` and a decision on TypeORM 0.3.
5. CI (build, vulnerability scan, push), then NetworkPolicy and TLS.

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

