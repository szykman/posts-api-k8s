#!/usr/bin/env bash
# Backup and restore of the bundled MariaDB: a logical dump taken through `kubectl exec`.
#
# Usage: scripts/db.sh backup [file]          default file: backups/posts-<UTC timestamp>.sql
#        scripts/db.sh restore <file> [--yes] replaces the tables with the ones in the dump
#
# The dump is consistent without locking (--single-transaction, InnoDB) and includes routines and triggers.
# A backup is only worth something if a restore has been tried: see `scripts/bootstrap.sh test --backup`.
# This is for the in-cluster database used locally. With a managed database use its own backups.
# shellcheck disable=SC2016
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-kind-posts}"   # never act on the current context by accident
NAMESPACE="${NAMESPACE:-posts}"
DB_POD="${DB_POD:-posts-api-db-0}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }
usage() { sed -n '/^# Usage:/,/^set -/p' "${BASH_SOURCE[0]}" | grep -v shellcheck | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }

# The credentials stay inside the pod: they come from the Secret the pod was started with.
# The variables are expanded by the shell inside the pod, not here, hence the single quotes.
DUMP_CMD='MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb-dump -uroot --single-transaction --routines --triggers "$MYSQL_DATABASE"'
LOAD_CMD='MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -uroot "$MYSQL_DATABASE"'

cmd_backup() {
  local file="${1:-backups/posts-$(date -u +%Y%m%dT%H%M%SZ).sql}" tmp
  command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed"
  umask 077   # a dump contains the data: readable by the owner only
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")"
  if ! kc -n "$NAMESPACE" exec "$DB_POD" -- sh -c "$DUMP_CMD" > "$tmp"; then
    rm -f "$tmp"; die "the dump failed (is the pod ${DB_POD} running?)"
  fi
  # A truncated dump would look like a backup and fail only when it is needed.
  if ! tail -n 1 "$tmp" | grep -q 'Dump completed'; then
    rm -f "$tmp"; die "the dump is incomplete, it was discarded"
  fi
  mv "$tmp" "$file"
  echo "backup written to ${file} ($(wc -c < "$file" | tr -d ' ') bytes)"
}

cmd_restore() {
  local file="${1:-}" yes="${2:-}" answer
  [ -n "$file" ] || usage
  [ -s "$file" ] || die "no such backup: ${file}"
  command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed"
  if [ "$yes" != "--yes" ]; then
    printf 'This replaces the tables in %s/%s with the contents of %s. Type "restore" to continue: ' "$NAMESPACE" "$DB_POD" "$file"
    read -r answer
    [ "$answer" = "restore" ] || die "cancelled"
  fi
  kc -n "$NAMESPACE" exec -i "$DB_POD" -- sh -c "$LOAD_CMD" < "$file"
  echo "restored from ${file}"
}

case "${1:-}" in
  backup) shift; cmd_backup "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  *) usage ;;
esac
