#!/bin/bash
# Apply claude-ui's schema to a database, rendering the host-neutral files for THIS host.
#   CLAUDE_UI_SCHEMA     data schema to create the tables in     (default: public)
#   CLAUDE_UI_API_SCHEMA schema PostgREST exposes, for the views + RPCs (default: api). Hosts whose PostgREST
#                        serves only `public` set it to public (and keep CLAUDE_UI_SCHEMA private, e.g. claudeui)
#   CLAUDE_UI_ADMIN_FN   SQL boolean expression gating the API   (default: <schema>.is_admin())
#   CLAUDE_UI_ANON_ROLE  PostgREST anonymous role                 (default: web_anon)
#   CLAUDE_UI_AUTH_ROLE  PostgREST authenticated role             (default: authenticated)
#   CLAUDE_UI_WHO_FN     SQL text expression naming the sender    (default: the first of the JWT claims
#                        handle, name, preferred_username, username, email, sub)
#   DBURI                connection string (env, or ../../.env when vendored)
# The API schema (CLAUDE_UI_API_SCHEMA, PostgREST's exposed schema) is assumed to exist. Views/functions are CREATE OR
# REPLACE; tables use plain CREATE TABLE and are skipped with an error line if they already exist.
set -e
cd "$(dirname "$0")"
# the host's .env fills in whatever the environment doesn't set: DBURI AND the CLAUDE_UI_* settings (sourcing it
# only when DBURI was unset rendered a host with DBURI exported for schema 'public', rewriting
# api.claude_send/claude_ctl to public.*). Values already in the environment win.
if [ -f ../../.env ]; then
  keep=$(for v in ${DBURI+DBURI} ${!CLAUDE_UI_*}; do printf '%s=%q\n' "$v" "${!v}"; done)
  set -a; source ../../.env; set +a
  eval "$keep"
fi
[ -z "$DBURI" ] && { echo "DBURI not set"; exit 1; }
S="${CLAUDE_UI_SCHEMA:-public}"
API="${CLAUDE_UI_API_SCHEMA:-api}"
ADMIN="${CLAUDE_UI_ADMIN_FN:-$S.is_admin()}"
ANON="${CLAUDE_UI_ANON_ROLE:-web_anon}"; AUTH="${CLAUDE_UI_AUTH_ROLE:-authenticated}"
WHO="${CLAUDE_UI_WHO_FN:-(SELECT coalesce(c->>'handle', c->>'name', c->>'preferred_username', c->>'username', c->>'email', c->>'sub') FROM (SELECT nullif(current_setting('request.jwt.claims', true), '')::json AS c) jwt)}"
esc() { printf '%s' "$1" | sed 's/[&/\]/\\&/g'; }
render() { sed -e "s/\\bapi\\./$API./g" -e "s/@SCHEMA@/$S/g" -e "s/@ADMIN@/$(esc "$ADMIN")/g" -e "s/@WHO@/$(esc "$WHO")/g" \
               -e "s/@ANON_ROLE@/$ANON/g" -e "s/@AUTH_ROLE@/$AUTH/g"; }
if [ "$1" = "--render" ]; then while read -r f; do [ -n "$f" ] && cat "schema/$f"; done < schema/order.txt | render; exit 0; fi
echo "applying claude-ui/sql/schema -> ${DBURI##*@}  (schema=$S api=$API admin=$ADMIN roles=$ANON/$AUTH)"
# columns added after a host first installed (tables are CREATE TABLE, skipped when they exist): add them
# BEFORE the stream, so the views and functions that use them apply cleanly
psql "$DBURI" -v ON_ERROR_STOP=1 -q -c "DO \$\$ BEGIN IF to_regclass('$S.claude_msg') IS NOT NULL THEN
    ALTER TABLE $S.claude_msg ADD COLUMN IF NOT EXISTS author text; END IF; END \$\$;"
while read -r f; do [ -n "$f" ] && cat "schema/$f"; done < schema/order.txt | render \
  | psql "$DBURI" -v ON_ERROR_STOP=0 -q 2>&1 | grep -iE "error" | grep -vE "already exists|multiple primary keys" | head -20 || true
psql "$DBURI" -qc "NOTIFY pgrst, 'reload schema';" 2>/dev/null || true
echo "done"
