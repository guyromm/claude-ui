#!/bin/bash
# Apply claude-ui's schema to a database, rendering the host-neutral files for THIS host.
#   CLAUDE_UI_SCHEMA     data schema to create the tables in     (default: public)
#   CLAUDE_UI_ADMIN_FN   SQL boolean expression gating the API   (default: <schema>.is_admin())
#   CLAUDE_UI_ANON_ROLE  PostgREST anonymous role                 (default: web_anon)
#   CLAUDE_UI_AUTH_ROLE  PostgREST authenticated role             (default: authenticated)
#   DBURI                connection string (env, or ../../.env when vendored)
# The `api` schema (PostgREST's exposed schema) is assumed to exist. Views/functions are CREATE OR
# REPLACE; tables use plain CREATE TABLE and are skipped with an error line if they already exist.
set -e
cd "$(dirname "$0")"
[ -z "$DBURI" ] && [ -f ../../.env ] && { set -a; source ../../.env; set +a; }
[ -z "$DBURI" ] && { echo "DBURI not set"; exit 1; }
S="${CLAUDE_UI_SCHEMA:-public}"
ADMIN="${CLAUDE_UI_ADMIN_FN:-$S.is_admin()}"
ANON="${CLAUDE_UI_ANON_ROLE:-web_anon}"; AUTH="${CLAUDE_UI_AUTH_ROLE:-authenticated}"
render() { sed -e "s/@SCHEMA@/$S/g" -e "s/@ADMIN@/$(printf '%s' "$ADMIN" | sed 's/[&/\]/\\&/g')/g" \
               -e "s/@ANON_ROLE@/$ANON/g" -e "s/@AUTH_ROLE@/$AUTH/g"; }
if [ "$1" = "--render" ]; then while read -r f; do [ -n "$f" ] && cat "schema/$f"; done < schema/order.txt | render; exit 0; fi
echo "applying claude-ui/sql/schema -> $DBURI  (schema=$S admin=$ADMIN roles=$ANON/$AUTH)"
while read -r f; do [ -n "$f" ] && cat "schema/$f"; done < schema/order.txt | render \
  | psql "$DBURI" -v ON_ERROR_STOP=0 -q 2>&1 | grep -iE "error" | grep -vE "already exists|multiple primary keys" | head -20 || true
psql "$DBURI" -qc "NOTIFY pgrst, 'reload schema';" 2>/dev/null || true
echo "done"
