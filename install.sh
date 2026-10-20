#!/bin/bash
# Install claude-ui into a host project that runs the usual stack (PostgREST on an `api` schema,
# SvelteKit under web/, workers under a tmux.sh registry, a pg_schema_dump.py).
#
#   cd <host project root>
#   git submodule add https://github.com/guyromm/claude-ui claude-ui
#   CLAUDE_UI_SCHEMA=<data schema> claude-ui/install.sh
#
# What it does: applies the schema (rendered for this host), writes the /admin/claude route, and
# prints the four one-line edits the host makes itself (they touch host-owned files, so they are
# shown, not applied). Re-runnable.
set -e
CUI="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
HOST="$(dirname "$CUI")"; cd "$HOST"
[ -f .env ] && { set -a; source .env; set +a; }
S="${CLAUDE_UI_SCHEMA:-public}"
echo "host: $HOST   data schema: $S   admin predicate: ${CLAUDE_UI_ADMIN_FN:-$S.is_admin()}"

# 1. schema
CLAUDE_UI_SCHEMA="$S" "$CUI/sql/apply.sh"
grep -q '^CLAUDE_UI_SCHEMA=' .env 2>/dev/null || printf '\n# claude-ui: data schema of its claude_* tables\nCLAUDE_UI_SCHEMA=%s\n' "$S" >> .env

# 2. the route (host-owned file, but there is nothing project-specific to decide in it)
R=web/src/routes/admin/claude; mkdir -p "$R"
[ -f "$R/+page.svelte" ] || cat > "$R/+page.svelte" <<'EOF'
<script>
  // /admin/claude = the claude-ui component mounted with this project's PostgREST endpoint and auth.
  import ClaudePage from "$claude-ui/ClaudePage.svelte";
  import { isAdmin, getToken } from "$lib/auth";
  import { PGRST } from "$lib/api";
</script>

<ClaudePage pgrst={PGRST} {getToken} {isAdmin} />
EOF
echo "route: $R/+page.svelte"

# 3. the host edits, shown
cat <<EOF

Now make these four edits in the host (each is one line):

  web/svelte.config.js   kit.alias: { '\$claude-ui': '../claude-ui/web' }
  web/vite.config.js     server.fs.allow: [searchForWorkspaceRoot(process.cwd()), path.resolve('../claude-ui')]
                         (only if server.fs.strict is on; imports: { searchForWorkspaceRoot } from 'vite', path from 'node:path')
  tmux.sh                after the WORKERS declarations:   source "\$DIR/claude-ui/tmux.sh"
  pg_schema_dump.py      after writing order.txt, delegate:
                           owned = set(subprocess.run([sys.executable, "claude-ui/pg_schema_dump.py", "--list"],
                                                      capture_output=True, text=True, check=True).stdout.split())
                           # drop those files + order.txt entries from your tree, then:
                           subprocess.run([sys.executable, "claude-ui/pg_schema_dump.py"], check=True)
  sql/apply.sh           last line:   ../claude-ui/sql/apply.sh

Then:  source tmux.sh && start voice-relay      and open /admin/claude as an admin.
Pin the relay to a session when there is more than one:  .voice_env with CLAUDE_VOICE_TRANSCRIPT / CLAUDE_VOICE_PANE.
EOF
