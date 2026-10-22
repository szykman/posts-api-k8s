# Runbook

What to do when something is wrong, in the order to look. Each entry has the same shape: **symptom**, **check**,
**likely cause**, **fix**, **verify**. The commands target the local kind cluster; the last section lists what changes
on GKE.

```bash
alias k='kubectl --context kind-posts -n posts'
alias h='helm --kube-context kind-posts -n posts'
```

Names used below: release `posts-api`, namespace `posts`, API Deployment `posts-api`, database pod `posts-api-db-0`,
migration Job `posts-api-migrate`, Secrets `posts-db-credentials`, `posts-api-token` and `posts-api-tls`.

## First five minutes

```bash
kubectl config current-context        # am I on the cluster I think I am?
kubectl --context kind-posts get nodes -L topology.kubernetes.io/zone
k get pods -o wide                    # state, node and restarts of every pod
k get events --sort-by=.lastTimestamp | tail -n 20
h status posts-api                    # is the release deployed, failed or pending?
```

Then pick the entry that matches what you see.

| You see | Go to |
|---|---|
| A pod `Pending` | [1](#1-an-api-pod-stays-pending) |
| Pods `Running` but `0/1` ready, or requests answer 503 | [2](#2-pods-are-running-but-not-ready) |
| `CrashLoopBackOff` or `Error` on an API pod | [3](#3-an-api-pod-crash-loops) |
| `helm upgrade` fails, or a migration Job failed | [4](#4-the-migration-job-failed) |
| `ErrImagePull` or `ImagePullBackOff` | [5](#5-the-image-cannot-be-pulled) |
| POST answers 401 | [6](#6-post-answers-401) |
| curl complains about the certificate, or answers 404 | [7](#7-tls-errors-or-404-from-the-ingress) |
| A node is `NotReady` | [8](#8-a-node-is-down) |
| The database is down or its data is wrong | [9](#9-the-database-is-down-or-has-bad-data) |
| A release behaves worse than the previous one | [10](#10-a-bad-release-roll-back) |
| The CI `publish` job fails | [11](#11-the-publish-job-fails) |

## 1. An API pod stays Pending

**Check**

```bash
k describe pod <pod> | sed -n '/Events:/,$p'
kubectl --context kind-posts get nodes        # SchedulingDisabled?
```

**Likely cause.** `FailedScheduling` with *didn't match pod topology spread constraints*. A node is cordoned or drained,
and placing the pod elsewhere would put two pods in one zone and none in another (skew 2, `maxSkew` is 1). This is the
intended behaviour of `whenUnsatisfiable: DoNotSchedule`: the pod waits instead of weakening the zone spread. The other
replicas keep serving.

Other causes: no node with enough CPU or memory for the requests; a node taint nobody tolerates.

**Fix.** Return the node (`kubectl --context kind-posts uncordon <node>`), or add capacity. Do not switch to
`ScheduleAnyway` to "make it go away": it removes the guarantee the constraint exists for.

**Verify.** `k get pods -o wide` shows one API pod per worker, all `Running`.

## 2. Pods are running but not ready

**Check**

```bash
k get pods                            # READY 0/1 with STATUS Running
k describe pod <pod> | grep -A3 -i readiness
k logs <pod> --tail=50
k get pod posts-api-db-0
```

**Likely cause.** `/ready` runs `SELECT 1` against the database with a 2 s limit and answers 503 when it fails, or
when the pod is shutting down. A database that is down or unreachable makes every pod unready, and the Service then has
no endpoints. `/health` (liveness) deliberately does not touch the database: restarting the API would not fix a broken
database, so the pods stay up and wait.

**Fix.** Fix the database first: [9](#9-the-database-is-down-or-has-bad-data). Check that the Secret
`posts-db-credentials` has the keys the chart documents (`MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE`) and that
`database.host` is right when an external database is used.

**Verify.** `k get pods` shows `1/1`, and `h test posts-api` passes.

## 3. An API pod crash-loops

**Check**

```bash
k logs <pod> --previous
k describe pod <pod> | sed -n '/State:/,/Ready:/p'
```

**Likely cause.** The API refuses to start without `API_TOKEN`, and the token must have at least 16 characters. The
Secret `posts-api-token` is missing, empty or too short. Next most likely: database variables missing from
`posts-db-credentials`.

**Fix.** Recreate the Secret with a valid value, then restart:

```bash
k create secret generic posts-api-token --from-literal=API_TOKEN="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | k apply -f -
k rollout restart deploy/posts-api
```

**Verify.** `k rollout status deploy/posts-api`, then `scripts/bootstrap.sh test`.

## 4. The migration Job failed

The migration runs as a Helm hook before the new pods roll out, so a failure stops the upgrade and the old version keeps
serving. Nothing is half deployed.

**Check**

```bash
k get jobs
k logs job/posts-api-migrate
k logs job/posts-api-migrate -c wait-for-db     # the init container that waits for the database
h history posts-api
```

**Likely cause.** The database was not reachable (the init container waits for it, up to
`migration.waitTimeoutSeconds`), the credentials are wrong, or the migration itself has an error. The Job retries up to
4 times (`backoffLimit`).

**Fix.** Correct the cause, then run the upgrade again; the hook deletes the previous Job
(`before-hook-creation`). If the migration code is wrong, ship a corrected image and a new tag.

**Verify.** `h status posts-api` shows `deployed`, and the Job completes.

**Careful.** A rollback does not revert the schema. If a migration already ran, the previous version must still work
with the new schema.

## 5. The image cannot be pulled

**Check**

```bash
k describe pod <pod> | sed -n '/Events:/,$p'
h get values posts-api | grep -A3 -i image
```

**Likely cause, in order.**

1. The tag does not exist in the registry (typo, or the tag was never published).
2. The image is private and the pod has no `imagePullSecrets`, or the Secret holds an expired or wrong token.
3. The registry is unreachable from the node.

**Fix.** For a private image, create the Secret with `scripts/create-pull-secret.sh` and set
`imagePullSecrets: [{name: regcred}]`. The token only needs read access to packages (`read:packages` on GHCR).

**Verify.** The pod reaches `Running`.

## 6. POST answers 401

A POST without a token, or with a wrong one, is **supposed** to answer 401 (with `WWW-Authenticate`). It is
a failure only when a valid token is refused.

**Check**

```bash
TOKEN="$(scripts/bootstrap.sh token)"
CA="$(scripts/bootstrap.sh ca)"
curl -i --cacert "$CA" --resolve posts.local:18443:127.0.0.1 \
  -X POST https://posts.local:18443/posts \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"title":"check","text":"x"}'
```

**Likely cause.** The Secret was changed but the pods still run with the old value. The chart puts a hash of the Secret
in a pod annotation, so a `helm upgrade` restarts them; a change made only with `kubectl` does not.

**Fix.** `h upgrade posts-api helm/posts-api --reuse-values`, or `k rollout restart deploy/posts-api`.

**Verify.** The command above answers `201`. Never use `curl -k`: it hides the very problem [7](#7-tls-errors-or-404-from-the-ingress)
describes.

## 7. TLS errors or 404 from the ingress

**Check**

```bash
CA="$(scripts/bootstrap.sh ca)"
openssl x509 -noout -subject -dates -ext subjectAltName -in "$CA"
k get ingress posts-api
k get secret posts-api-tls
kubectl --context kind-posts -n traefik get pods
```

| Symptom | Cause |
|---|---|
| `certificate verify failed` | Missing `--cacert`, or the certificate was regenerated and the local copy is stale |
| `certificate has expired` | The self-signed certificate is valid for one year |
| 404 on HTTPS | Wrong `Host` (the ingress matches `posts.local`; the script uses `--resolve`) |
| 404 on the plain HTTP port | By design: the API is HTTPS only |
| Connection refused | Traefik pod not running, or ports 18080 and 18443 taken on the host |

**Fix.** Re-run `scripts/bootstrap.sh up`: it is idempotent and keeps existing Secrets, so to renew the certificate
delete `posts-api-tls` first (`k delete secret posts-api-tls`). In a cloud cluster the certificate comes from
cert-manager and renews itself.

**Verify.** `scripts/bootstrap.sh test`.

## 8. A node is down

**Check**

```bash
kubectl --context kind-posts get nodes
kubectl --context kind-posts describe node <node> | sed -n '/Conditions:/,/Addresses:/p'
docker ps -a --filter name=posts-            # the nodes are containers on this host
```

**What to expect.** This is an involuntary disruption, so the PodDisruptionBudget does not apply. The API pods on the
other two zones keep serving; the lost pod is recreated elsewhere only if the zone spread allows it, otherwise it waits
`Pending` ([1](#1-an-api-pod-stays-pending)). The bundled database is one instance with a volume bound to its node: if
that node is the one down, the database, and with it the API, is unavailable until the node returns. That limit is
documented in [ADR 0004](decisions/0004-database-availability.md); a managed regional database removes it.

**Fix.** On kind, `docker start <node>` or `docker restart <node>`. On a cloud cluster, the node pool repairs or
replaces the node.

**Verify.** All nodes `Ready`, all pods `Running`, `scripts/bootstrap.sh test`.

## 9. The database is down or has bad data

**Check**

```bash
k get pod posts-api-db-0
k logs posts-api-db-0 --tail=50
k get pvc
```

**Fix, service down.** If the pod is `Pending`, check its node and its volume claim. The pod only starts on the node
that holds its volume.

**Fix, bad or lost data.** Restore the last dump:

```bash
scripts/db.sh backup                        # take a dump first, if the database still answers
ls backups/
scripts/db.sh restore backups/<file>.sql    # replaces the tables with the ones in the dump
```

A backup is only worth something if a restore has been tried: `scripts/bootstrap.sh test --backup` does exactly that.
These scripts are for the bundled database. With a managed database use its own backups and point-in-time recovery.

**Verify.** `k get pods` all `1/1`, then `curl` the `GET /posts` endpoint and compare with what you expect.

## 10. A bad release: roll back

```bash
h history posts-api
h rollback posts-api <revision>
k rollout status deploy/posts-api
scripts/bootstrap.sh test
```

A rollback returns the chart and the image to a previous revision without interrupting traffic (the upgrade test
checks this). It does **not** run the migration hook and does **not** revert the schema, so it is only safe while schema
changes stay backward compatible. If a migration made an incompatible change, restore from a dump
([9](#9-the-database-is-down-or-has-bad-data)) as well.

## 11. The publish job fails

| Message | Cause and fix |
|---|---|
| `... already exists in the registry; bump appVersion` | Images are immutable: a published tag is never overwritten. Bump `appVersion` and `version` in `Chart.yaml`, commit, tag the new version |
| `tag vX does not match appVersion Y` | The Git tag must equal `v` plus the chart `appVersion`. Fix `Chart.yaml` or tag the right commit |
| Trivy finds a HIGH or CRITICAL with a fix | Update the base image digest or the dependency, or remove the package from the runtime image (this is how npm was removed) |

## On GKE

| Local | GKE |
|---|---|
| `--context kind-posts` | The context from `gcloud container clusters get-credentials`; always keep `--context` explicit |
| Node is a Docker container | `kubectl describe node`; Autopilot repairs nodes itself |
| Bundled MariaDB, `scripts/db.sh` | Cloud SQL: its own backups, failover and point-in-time recovery |
| Self-signed certificate | cert-manager and Let's Encrypt; check `kubectl describe certificate` |
| `helm upgrade` / `rollback` | Argo CD sync; roll back by reverting the commit or the `targetRevision` |
| `docker logout`, local tokens | Workload Identity; no pull Secret for Artifact Registry in the same project |

This page covers what the project actually ships. Metrics, alerts and on-call are not built yet; until they are, the
first sign of a problem is a failed test or a person noticing.
