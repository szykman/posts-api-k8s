# Taking this to GKE (a primer, and the record of one trial)

`terraform/` and `gitops/` were applied once to a real GKE Autopilot cluster in a trial project (22 October 2026), with
the bundled database, a self-signed certificate and no domain. The Cloud SQL, cert-manager and External Secrets parts
have not been applied. CI validates the syntax (`terraform validate`, YAML parse, chart schema). Everything also runs
locally on kind; this page explains how each local piece maps to GKE and what the trial showed.

## GKE in five lines

- **GKE** is Google's managed Kubernetes: Google runs the control plane; you run workloads.
- **Autopilot** (used here) also manages the nodes and bills for the resources your pods request. **Standard**
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
2. In a new project the Cloud Resource Manager API is off, and Terraform needs it to enable the other APIs. Turn it on
   once by hand, otherwise the first `apply` fails with `Cloud Resource Manager API has not been used`:
   ```bash
   gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com
   ```
   Also check that the project is linked to an open billing account (`gcloud billing projects describe <project>`
   must say `billingEnabled: true`). Then, in Cloud Shell (which has `gcloud` and `kubectl` but may not have
   `terraform`: download the binary into `~/bin`) or after `gcloud auth application-default login`:
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
   kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl apply -f gitops/argocd/traefik.yaml
   ```
   Before `posts-api.yaml`: replace the host and database host, and create the two Secrets by hand for the trial
   (`kubectl -n posts create secret generic posts-db-credentials ...`, `posts-api-token ...`, as in `bootstrap.sh`).
   For a trial without a domain, keep the bundled MariaDB (`mariadb.enabled: true`) with the migration hook
   `post-install,post-upgrade`, a self-signed certificate in the Secret `posts-api-tls`, and test through the load
   balancer IP with `--resolve`. (`--server-side` avoids a size error on the Argo CD CRDs. The default hook
   `post-install,pre-upgrade` does not work under Argo CD with the bundled database, see below.)
4. **Destroy when done**, in this order, so nothing is left billing: first what Argo and Kubernetes created, then
   Terraform (`deletion_protection = false` in `terraform.tfvars` first):
   ```bash
   kubectl -n argocd delete application posts-api traefik   # removes the Traefik load balancer
   kubectl -n posts delete pvc --all                        # the MariaDB disk survives its StatefulSet
   terraform destroy
   ```
   Confirm in the console that no disk, load balancer or forwarding rule is left. Keep `terraform.tfstate`: without it
   Terraform cannot destroy what it created.

## What the trial showed (22 October 2026)

Two things the syntax checks could never catch, both fixed in this repository:

- **A fresh project cannot enable APIs by itself.** The first `terraform apply` failed on every `google_project_service`
  with `Cloud Resource Manager API has not been used`. The fix is the `gcloud services enable` line in step 2.
- **The default migration hook deadlocks under Argo CD with the bundled database.** Argo CD runs `pre-upgrade` hooks as
  PreSync and cannot tell the first sync from an upgrade, so the migration Job ran before the database existed, timed
  out waiting for it, and the sync never created the database. With the bundled MariaDB use
  `migration.hook: post-install,post-upgrade` (PostSync); with an external database `pre-install,pre-upgrade` is right.

What worked: `terraform apply` created 9 resources and the Autopilot cluster in under 4 minutes; Argo CD synced Traefik
(three replicas, one external IP) and the chart; the API answered over HTTPS with the certificate verified (no `-k`),
`POST` without a token gave 401 and with the token 201; the three API pods were spread over `southamerica-east1-a`,
`-b` and `-c`; and deleting API pods while a loop of requests ran returned only 200. The bundled MariaDB landed on the
same node as one API pod and its disk is tied to one zone, which is the reason production uses Cloud SQL.

The local scripts (`bootstrap.sh`, `resilience-test.sh`) are kind-only; on GKE the equivalent checks were run by hand.

## What is missing for a real production

cert-manager and DNS; Secret Manager and External Secrets; NetworkPolicy; Workload Identity for anything that calls
Google APIs; Cloud SQL Auth Proxy or private IP with TLS to the database; a private cluster with authorized
networks; separate projects and state per environment; monitoring and alerts (Cloud Monitoring, Prometheus);
scheduled backups copied outside the cluster; and an image-signing/admission policy.
