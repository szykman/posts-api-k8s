# Taking this to GKE (a primer, and a sketch that was never applied)

Nothing in `terraform/` or `gitops/` has been applied to a real cluster. They are validated for syntax in CI
(`terraform validate`, YAML parse, chart schema) and are meant to show the shape of the production setup and to be a
safe starting point. Everything runs locally on kind; this page explains how each local piece maps to GKE.

## GKE in five lines

- **GKE** is Google's managed Kubernetes: Google runs the control plane; you run workloads.
- **Autopilot** (used in the sketch) also manages the nodes and bills for the resources your pods request. **Standard**
  gives you node pools and machine types and bills for the nodes.
- A **regional** cluster spreads the control plane and nodes over three zones of a region. That is the real
  version of the `zone-a/b/c` labels used on kind, and the same `topologySpreadConstraints` work unchanged
  (the label `topology.kubernetes.io/zone` is set by GKE).
- Pods reach Google services with **Workload Identity** (a Kubernetes service account mapped to a Google service
  account) instead of key files.
- A `Service` of type `LoadBalancer` creates a Google load balancer that is reachable from all zones.

## What maps to what

| Local (kind) | GKE | Where |
|---|---|---|
| `kind/cluster.yaml`, 3 labelled workers | Regional Autopilot cluster, 3 real zones | `terraform/gcp/main.tf` |
| Traefik with `hostPort` on the control plane | Traefik `Service` of type `LoadBalancer`, 3 replicas spread over zones | `gitops/argocd/traefik.yaml` |
| Self-signed certificate made by `bootstrap.sh` | cert-manager + Let's Encrypt (ADR 0003, option 4) | annotation in `gitops/argocd/posts-api.yaml` |
| Bundled single MariaDB | Cloud SQL for MySQL, regional HA, private IP (ADR 0004) | `terraform/gcp/main.tf` (`create_database`) |
| ghcr.io public image | Same image, or a copy in Artifact Registry pulled with the node identity (no pull Secret) | `terraform/gcp/main.tf` |
| `bootstrap.sh up` and `helm upgrade` | Argo CD syncs the chart from Git | `gitops/argocd/posts-api.yaml` |
| Secrets created by `bootstrap.sh` | Secret Manager + External Secrets (or Sealed Secrets) | not built |
| Tests run by hand / in CI on kind | Same tests against a staging cluster, then promote the tag | not built |

## Terraform, briefly

Terraform describes infrastructure in files, compares it to the real state (`plan`), and makes the difference true
(`apply`). The **state** records what exists; it holds secrets, so it lives in a locked, versioned bucket and never
in Git. Helm stays in charge of the application; Terraform owns the cluster, network, registry and database. In a
team, Terragrunt keeps the per-environment configuration DRY and Atlantis runs `plan`/`apply` from pull requests so
that every change is reviewed and applied by one pipeline, not from laptops.

## Trying it cheaply and safely

1. Create a **new, dedicated project** and a **budget alert** (Billing > Budgets) at a low value before anything else.
   Deleting the project removes everything in it.
2. `gcloud auth application-default login`, then:
   ```bash
   cd terraform/gcp
   cp terraform.tfvars.example terraform.tfvars   # set project_id; keep create_database = false
   terraform init && terraform plan
   terraform apply
   $(terraform output -raw get_credentials)
   ```
   Autopilot only bills for pods that run, so an idle cluster is cheap, but a cluster management fee can apply
   (one cluster per billing account is covered by a monthly credit; check the current pricing page).
3. Install Argo CD, then apply the two Applications:
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl apply -f gitops/argocd/traefik.yaml
   ```
   Before `posts-api.yaml`: replace the host and database host, and create the two Secrets by hand for the trial
   (`kubectl -n posts create secret generic posts-db-credentials ...`, `posts-api-token ...`, as in `bootstrap.sh`).
   For a trial without a domain, keep the bundled MariaDB (`mariadb.enabled: true`, hook `post-install,pre-upgrade`)
   and test through the load balancer IP with `--resolve`.
4. **Destroy when done:** `terraform destroy` (set `deletion_protection = false` first), or delete the project.
   Remember the load balancer and any disks: confirm in the console that nothing is left.

## What is missing for a real production

cert-manager and DNS; Secret Manager and External Secrets; NetworkPolicy; Workload Identity for anything that calls
Google APIs; Cloud SQL Auth Proxy or private IP with TLS to the database; a private cluster with authorized
networks; separate projects and state per environment; monitoring and alerts (Cloud Monitoring, Prometheus);
scheduled backups copied outside the cluster; and an image-signing/admission policy.
