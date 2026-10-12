# 4. Database availability: what is built, and how to make it highly available

Status: accepted (the single instance is a conscious limit; the path to HA is documented, not built)

## Context

The API runs as three replicas across three zones and survives the loss of a node or a zone. The bundled
MariaDB is one pod with one volume (`StatefulSet`, 1 replica, 1Gi). If its node or zone is lost, writes and
reads stop until the pod is scheduled again and its volume is attached, and if the volume is lost the data is
lost. The API stays up in that case (liveness does not depend on the database) but `/ready` fails and the
Service has no ready endpoint, so the user sees errors.

"Highly available" for a database means two numbers, and it helps to name them before choosing anything:

- **RTO** (recovery time objective): how long writes may be down after a failure.
- **RPO** (recovery point objective): how much recent data may be lost.

A **backup is not high availability**. A backup bounds the data loss after a disaster (RPO = time since the last
backup) and the recovery takes minutes to hours (RTO); high availability keeps a live copy that takes over in
seconds with no or almost no loss.

## Options

| # | Option | RTO | RPO | Cost / effort | Notes |
|---|---|---|---|---|---|
| 0 | Single pod + backups (**what is built**) | minutes to hours (reschedule or restore) | time since last backup | none | Fine for a challenge or a non-critical service |
| 1 | Managed database with a standby in another zone (Cloud SQL for MySQL "high availability", RDS Multi-AZ) | typically about a minute or two, automatic | zero for committed data (synchronous standby) | paid service, almost no work | Needs a cloud account. Cloud SQL offers MySQL, not MariaDB, so the engine changes |
| 2 | MariaDB with an operator (primary + replicas, automatic failover; the mariadb-operator project covers replication, Galera, proxying and backups) | seconds to a minute | zero or a few transactions (semi-synchronous) or more (asynchronous) | runs in our cluster; we operate it | Keeps the engine. Needs three volumes, ideally one per zone |
| 3 | Galera cluster (three synchronous multi-primary nodes) | seconds | zero | most to operate: quorum, split brain, slow writes across zones | Needs an odd number of nodes (3) |
| 4 | Primary + replica by hand, manual promotion | minutes (a human) | replication lag | cheap, fragile | Not recommended: the failover is the hard part |

## Decision

1. **Local and challenge environment: option 0.** One MariaDB pod, a tested backup and restore
   (`scripts/db.sh`, proved by `bootstrap.sh test --backup`), and the limit stated in the README. A replicated
   database on a laptop with simulated zones would add many moving parts without proving real zone failover.
2. **Production on GKE: option 1** (Cloud SQL for MySQL, regional high availability, private IP), because a team that
   wants to ship features should not run its own database failover. The chart is ready for it:
   `--set mariadb.enabled=false --set database.host=<private IP or proxy>` and, if Argo CD drives the release,
   `--set 'migration.hook=pre-install\,pre-upgrade'` (see "Why the hook value changes" below).
3. **If the engine must stay MariaDB and the data must stay in the cluster: option 2.** An operator, not hand-written
   StatefulSets.

## What changes in the application for any of the HA options

- **Connection endpoint.** The API must point to a stable name that follows the primary (the Cloud SQL private IP, or the
  operator's primary Service), not to a pod. This is just `database.host`.
- **Reconnection.** After a failover the existing connections break. The `mysql2` pool opens new connections on
  demand, and `/ready` removes a pod from the Service while it cannot reach the database, so the API recovers on its
  own. This was reasoned from the design, not tested against a real failover; it is the first thing to test.
- **Migrations** must run against the primary. They are idempotent, and the hook runs once per release.
- **The Secret** holds the credentials of the new database; nothing in the image changes.

## Why the hook value changes with an external database

With the bundled database the migration runs as `post-install` on the first install, because the database is part of
the same release and does not exist yet during `pre-install`. With an external database it already exists, so the
migration can (and should) run before the new pods start: `pre-install,pre-upgrade`. Argo CD translates `pre-install`
and `pre-upgrade` hooks into a `PreSync` phase, which is the order wanted in a GitOps flow.

## Runbook: backup and restore (built and tested)

```bash
scripts/db.sh backup                 # writes backups/posts-<UTC time>.sql, mode 600, refuses a truncated dump
scripts/db.sh restore backups/<file> # asks you to type "restore"; replaces the data in the database
scripts/bootstrap.sh test --backup   # creates a post, backs up, deletes it, restores, checks it is back
```

- The dump uses `mariadb-dump --single-transaction`, so it is consistent without locking writers, and includes
  routines and triggers. The root password is read inside the pod and never appears on a command line.
- Backups land in `backups/`, which is ignored by Git. They contain the data and must be treated as sensitive.
- **Not built:** scheduled backups and copies outside the cluster. A backup that lives next to the database is
  lost with it. The production shape is a `CronJob` that runs the same dump and uploads it to object storage with
  a retention rule, plus a periodic restore test (a backup that was never restored is a hope, not a backup).
- On Cloud SQL the equivalent is automated backups plus point-in-time recovery, with no job of our own.

## How to try the failover (when an HA option exists)

1. Start a write loop through the ingress (`scripts/resilience-test.sh` shows the pattern).
2. Delete the primary pod (operator) or trigger a manual failover (`gcloud sql instances failover`).
3. Measure the seconds with failed requests (RTO) and compare the ids written before and after (RPO).

## Consequences

- The documented limit is honest: the database is the single point of failure of the local setup.
- The cost of HA is moved to where it is cheapest (a managed service) and the chart already supports it.
- Choosing Cloud SQL means MySQL instead of MariaDB in production; the application uses the common SQL subset, but
  the production engine should also be used in CI before going live.
