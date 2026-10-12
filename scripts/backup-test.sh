#!/usr/bin/env bash
# Backup and restore test: a backup that was never restored proves nothing.
#
# Creates a post through the API, takes a backup, deletes the post straight in the database (as an accident
# would), checks that the API no longer finds it, restores the backup and checks that the post is back.
#
# Usage: scripts/backup-test.sh        (also: scripts/bootstrap.sh test --backup)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-posts}"   # never act on the current context by accident
NAMESPACE="${NAMESPACE:-posts}"
DB_POD="${DB_POD:-posts-api-db-0}"
export KUBE_CONTEXT NAMESPACE DB_POD

# shellcheck source=lib/ingress.sh
. "$ROOT/scripts/lib/ingress.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

for tool in kubectl curl base64; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
load_ca "$KUBE_CONTEXT" "$NAMESPACE" || exit 2

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

token="$(kc -n "$NAMESPACE" get secret posts-api-token -o jsonpath='{.data.API_TOKEN}' | base64 -d)"
title="backup-test-$(date +%s)"

echo "== 1. Create a post through the API"
out="$(icurl -sS -X POST -H "Authorization: Bearer ${token}" -H 'content-type: application/json' \
  -d "{\"title\":\"${title}\",\"text\":\"must survive a restore\"}" -w $'\n%{http_code}' "${INGRESS_URL}/posts")"
code="${out##*$'\n'}"; body="${out%$'\n'*}"
[ "$code" = "201" ] || die "POST /posts answered ${code}: ${body}"
id="$(printf '%s' "$body" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')"
[ -n "$id" ] || die "no id in the answer: ${body}"
echo "post ${id} created"

echo "== 2. Backup"
"$ROOT/scripts/db.sh" backup "$WORK/backup.sql"

echo "== 3. Delete the post in the database, as an accident would"
kc -n "$NAMESPACE" exec "$DB_POD" -- sh -c \
  "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mariadb -uroot \"\$MYSQL_DATABASE\" -e 'DELETE FROM post WHERE id=${id}'"
code="$(icurl -s -o /dev/null -w '%{http_code}' "${INGRESS_URL}/posts/${id}")"
[ "$code" = "404" ] || die "the post should be gone (expected 404), got ${code}"
echo "ok  the API no longer finds post ${id}"

echo "== 4. Restore"
"$ROOT/scripts/db.sh" restore "$WORK/backup.sql" --yes
out="$(icurl -fsS "${INGRESS_URL}/posts/${id}")"
case "$out" in *"$title"*) ;; *) die "the restored post is not what was backed up: ${out}" ;; esac
echo "ok  post ${id} is back after the restore"
echo "== Backup and restore test passed"
