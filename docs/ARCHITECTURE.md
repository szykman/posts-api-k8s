# Architecture

Six diagrams, from the running system to the cloud target. They are written in Mermaid, so GitHub renders them and
they stay in Git next to the code they describe. The README has a short text version of the first one; the reasoning
behind each choice is in [`docs/decisions/`](decisions/).

| # | Diagram | Answers |
|---|---|---|
| 1 | [Runtime architecture](#1-runtime-architecture) | What runs where? |
| 2 | [A request through the ingress](#2-a-request-through-the-ingress) | Where is TLS terminated and where is the token checked? |
| 3 | [From commit to cluster](#3-from-commit-to-cluster) | How does a change reach the cluster, and what stops a bad one? |
| 4 | [Draining a node](#4-draining-a-node) | Why does the API keep answering while a node is taken away? |
| 5 | [GKE target](#5-gke-target-a-sketch-never-applied) | What would production look like? |
| 6 | [Observability](#6-observability-opt-in) | How do the metrics get from a pod to an alert? |

## 1. Runtime architecture

The local cluster is a [kind](https://kind.sigs.k8s.io/) cluster: real Kubernetes, with each node running as a Docker
container. The three workers carry the labels `zone-a`, `zone-b` and `zone-c`, so the zone-aware scheduling is real
even though the zones are simulated.

```mermaid
flowchart TB
    client["Client: curl --cacert --resolve posts.local"]
    port["Host 127.0.0.1:18443 (loopback only) -> node port 443"]

    subgraph cluster["kind cluster 'posts'"]
        subgraph cp["posts-control-plane"]
            traefik["Traefik ingress controller (hostPort 443, namespace traefik)"]
        end

        subgraph ns["namespace posts"]
            ing["Ingress posts-api (host posts.local, TLS Secret posts-api-tls)"]
            svc["Service posts-api (ClusterIP :80, PodDisruptionBudget maxUnavailable 1)"]

            subgraph za["posts-worker (zone-a)"]
                p1["API pod"]
            end
            subgraph zb["posts-worker2 (zone-b)"]
                p2["API pod"]
            end
            subgraph zc["posts-worker3 (zone-c)"]
                p3["API pod"]
            end

            svcdb["Service posts-api-db (ClusterIP :3306)"]
            sts["StatefulSet posts-api-db-0 (MariaDB 10.11, 1Gi PVC)"]
            job["Job posts-api-migrate (Helm hook)"]
        end
    end

    client --> port --> traefik --> ing --> svc
    svc --> p1
    svc --> p2
    svc --> p3
    p1 --> svcdb
    p2 --> svcdb
    p3 --> svcdb
    svcdb --> sts
    job -. "migrations" .-> svcdb
```

Points worth knowing:

- Only Traefik is reachable from outside. The database Service is a ClusterIP and nothing is published for it.
- The API pods are spread by `topologySpreadConstraints` (`maxSkew: 1`, `DoNotSchedule`, key
  `topology.kubernetes.io/zone`), one pod per zone.
- The single MariaDB instance is bundled for local and demo use. Its volume is bound to one node, which is why the
  resilience test never drains the node that hosts it. In production the database is managed
  ([ADR 0004](decisions/0004-database-availability.md)).

## 2. A request through the ingress

TLS ends at Traefik. Between Traefik and the pod, and between the pod and the database, traffic is plain
([ADR 0003](decisions/0003-https-at-the-ingress.md)). Writes need a bearer token
([ADR 0002](decisions/0002-authenticate-writes.md)).

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant T as Traefik
    participant A as API pod
    participant D as MariaDB

    C->>T: HTTPS, Host posts.local (certificate verified with --cacert)
    Note over T: TLS ends here
    T->>A: HTTP, routed by Host and path

    alt GET /posts
        A->>D: SELECT
        D-->>A: rows
        A-->>C: 200 and the posts
    else POST /posts without a valid token
        A-->>C: 401 and WWW-Authenticate
    else POST /posts with a valid token
        A->>D: INSERT
        D-->>A: ok
        A-->>C: 201
    end

    C->>T: HTTP on the plain port
    T-->>C: 404 (the API is HTTPS only)
```

## 3. From commit to cluster

Every change goes through the same gates, and publishing is a separate, deliberate step: pushing a `v*` tag.

```mermaid
flowchart TB
    dev["Commit / pull request"] --> ci

    subgraph ci["CI (GitHub Actions)"]
        direction LR
        test["test: unit tests and dependency audit"]
        lint["lint: hadolint, helm lint, shellcheck"]
        tf["terraform: validate and format check"]
        scan["scan: Trivy, CRITICAL and HIGH with a fix"]
        e2e["e2e: bootstrap.sh up and test on kind"]
        test --> e2e
        lint --> e2e
    end

    ci --> tag{"Tag v* pushed?"}
    tag -- "no" --> stop["Nothing is published"]
    tag -- "yes" --> check["Tag must equal Chart appVersion"]
    check --> pub["publish: build.sh --push (a tag that exists is refused)"]
    pub --> reg[("ghcr.io/szykman/posts-api")]

    reg --> deploy{"How is it deployed?"}
    deploy -- "by hand" --> helm["helm upgrade"]
    deploy -- "GitOps (sketch)" --> argo["Argo CD sync"]

    helm --> pre["pre-upgrade hook: migration Job"]
    argo --> pre2["PreSync hook: migration Job"]
    pre --> roll["Rolling update: maxUnavailable 0, maxSurge 1"]
    pre2 --> roll
```

- `publish` needs `test`, `lint`, `scan` and `e2e` to pass, and only runs for tags, so a push to `main` never
  publishes.
- A failed migration stops the upgrade before any new pod starts, so the old version keeps serving.
- `helm rollback` does not revert the schema, so schema changes must stay backward compatible.

## 4. Draining a node

What `scripts/resilience-test.sh` shows, step by step. With one pod per zone and `DoNotSchedule`, the evicted pod waits
instead of doubling up in another zone.

```mermaid
sequenceDiagram
    autonumber
    participant Op as Operator
    participant K as Kubernetes API
    participant S as Scheduler
    participant N as Node (zone-a)
    participant P as API pod

    Op->>K: kubectl drain (cordon, then evict)
    K->>N: node marked unschedulable
    K->>K: eviction allowed? PDB maxUnavailable 1, so yes
    K->>P: pod Terminating
    Note over P: removed from the Service endpoints, preStop sleep 5s, then SIGTERM, /ready answers 503
    P-->>K: exits within the 30s grace period
    K->>S: new pod needed
    S->>S: other zones would give skew 2 (2 vs 0), maxSkew is 1
    S-->>K: no node fits, pod stays Pending
    Note over Op,P: the other two pods keep serving, 0 failed requests
    Op->>K: kubectl uncordon
    K->>S: zone-a is schedulable again
    S->>N: new pod placed, spread back to 1-1-1
```

The PDB protects against voluntary disruptions (drain, upgrade). A node that dies suddenly is an involuntary
disruption; the spread across zones and the readiness probes cover that case.

## 5. GKE target (a sketch, never applied)

`terraform/gcp/` and `gitops/argocd/` describe this. They are validated for syntax in CI and have not been applied to a
real project. See [GKE.md](GKE.md) for the mapping from each local piece.

```mermaid
flowchart TB
    subgraph tfgrp["Terraform (terraform/gcp)"]
        vpc["VPC and subnet"]
        gke["Regional GKE Autopilot cluster (3 zones)"]
        ar["Artifact Registry"]
        sql["Cloud SQL for MySQL, regional HA, private IP (optional: create_database)"]
    end

    subgraph k8s["Inside the cluster"]
        argo["Argo CD"]
        traefik2["Traefik (Service type LoadBalancer, 3 replicas)"]
        cm["cert-manager (Let's Encrypt)"]
        api["posts-api chart (Helm)"]
    end

    git[("Git: helm/posts-api, gitops/argocd")]
    users["Users"]

    vpc --> gke
    vpc --> sql
    gke --- k8s
    git --> argo
    argo --> traefik2
    argo --> api
    cm --> traefik2
    users --> traefik2 --> api
    api --> sql
    ar -. "image" .-> api
```

Terraform owns the infrastructure, Helm owns the application, and Argo CD keeps the cluster equal to Git. Secrets never
go in Git (External Secrets or Sealed Secrets are the planned route, not built).

## 6. Observability (opt-in)

The API exposes its metrics on a separate port, 9100. The Service and the Ingress publish only the API port, so the
metrics are reachable from inside the cluster and never from outside. `scripts/observability.sh up` installs
kube-prometheus-stack and switches on the three objects the chart carries.

```mermaid
flowchart TB
    subgraph mon["namespace monitoring (kube-prometheus-stack)"]
        op["Prometheus Operator"]
        prom["Prometheus"]
        ksm["kube-state-metrics"]
        graf["Grafana"]
    end

    subgraph app["namespace posts (the chart)"]
        pm["PodMonitor"]
        rule["PrometheusRule: 5 alerts"]
        dash["ConfigMap: dashboard"]
        pod["API pod: :3000 API, :9100 metrics"]
    end

    ing["Ingress: publishes :3000 only"]

    ing --> pod
    pm --> op
    rule --> op
    op --> prom
    dash --> graf
    ksm --> prom
    prom -- "scrapes :9100 every 30 s" --> pod
    graf -- "queries" --> prom
```

- The chart's objects are plain Kubernetes resources; the Operator turns them into Prometheus configuration. That is why
  they are off by default: without the Operator's CRDs a `PodMonitor` cannot even be created.
- A `PodMonitor` is used instead of a `ServiceMonitor` because the Service deliberately does not publish the metrics
  port.
- Alertmanager is not installed locally, so the alerts are evaluated and visible in Prometheus, and nobody is notified.
