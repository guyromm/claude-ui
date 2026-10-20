# claude-ui — a phone/voice channel to a running Claude Code session

A small web page plus a relay that let you read and drive a `claude` CLI session from a phone:
messages you type (or dictate) are typed into the session's tmux pane; the session's replies are
mirrored from its transcript into a table the page polls; a working/waiting indicator, suggested
replies, read-aloud, and voice commands ("send", "clear", "scratch that", "read it back", "stop",
"stop listening") come along. Any worker on the host can also push a line into the session with
`bin/notify_claude.sh "…"`.

It is meant to be vendored into a host project (a git submodule) that already runs PostgreSQL +
PostgREST, a SvelteKit app and a tmux worker registry; the host mounts the page on a route of its own.

## Layout

```
web/ClaudePage.svelte      the page, as a Svelte component with a 3-prop host contract
relay/claude_voice_relay.py  the worker: transcript -> DB (OUT), DB -> tmux send-keys (IN), status
relay/db.py                the relay's own DB access (no host imports)
bin/notify_claude.sh       type "NOTIFY: <msg>" into the claude pane (deduped, fail-open)
tmux.sh                    worker registry (+ notify_claude) -- the host SOURCES it
pg_schema_dump.py          dumps claude-ui's own DB objects into sql/schema; --list names them
sql/schema/*.sql           tables, views, RPCs, grants  (order.txt = apply order)
sql/apply.sh               apply them to a database
```

## Separation of concerns: what the host does, and all it knows

The host never names a claude-ui worker or object. It delegates three verbs:

| verb          | host side                                                                                                                              | claude-ui side                                                                                          |
|---------------|----------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| start workers | `source claude-ui/tmux.sh` inside its own `tmux.sh`                                                                                    | registers `WORKERS[...]`/`WORKER_WINDOWS[...]`, defines `notify_claude`, lists itself via `cui_workers` |
| dump schema   | its `pg_schema_dump.py` calls `claude-ui/pg_schema_dump.py --list` to drop our files from its tree, then `claude-ui/pg_schema_dump.py` | writes `sql/schema` from the live DB, selecting objects it owns (all named `claude_*`)                  |
| apply schema  | its `sql/apply.sh` chains `claude-ui/sql/apply.sh` last                                                                                | applies `sql/schema` in `order.txt` order                                                               |
	
## Installing into a project (git submodule)

Assumes the shared stack: PostgREST serving an `api` schema with `web_anon` / `authenticated`
roles, a SvelteKit app under `web/` with `$lib/auth` (`getToken`, `isAdmin`) and `$lib/api`
(`PGRST`), workers under a `tmux.sh` registry (`DIR`, `PYBIN`, `WORKERS`, `WORKER_WINDOWS`), and a
`pg_schema_dump.py` that writes `sql/schema/`.

```
cd <project root>
git submodule add https://github.com/guyromm/claude-ui claude-ui
CLAUDE_UI_SCHEMA=<your data schema> claude-ui/install.sh
```

`install.sh` applies the schema (rendered for your schema, admin predicate and roles), writes the
`/admin/claude` route, and prints the four one-line edits to host-owned files (`svelte.config.js`,
`vite.config.js`, `tmux.sh`, `pg_schema_dump.py`, `sql/apply.sh`). Then `start voice-relay`.

**What is parameterised, and how** — the committed SQL is host-neutral; these render it:

| placeholder                                                                    | env                                           | default                                |
|--------------------------------------------------------------------------------|-----------------------------------------------|----------------------------------------|
| `@SCHEMA@` — data schema holding `claude_msg` / `claude_ctl` / `claude_status` | `CLAUDE_UI_SCHEMA`                            | `public`                               |
| `@ADMIN@` — boolean SQL expression gating every API object                     | `CLAUDE_UI_ADMIN_FN`                          | `<schema>.is_admin()`                  |
| `@ANON_ROLE@` / `@AUTH_ROLE@` — PostgREST roles in the grants                  | `CLAUDE_UI_ANON_ROLE` / `CLAUDE_UI_AUTH_ROLE` | `web_anon` / `authenticated`           |

The relay finds the session transcript under `~/.claude/projects/<host path with / as ->/` from
`CLAUDE_UI_HOST_DIR` (set by `tmux.sh`), and reads the tables through `search_path`, so nothing in
it names a schema. `api` itself is not parameterised: it is the stack's PostgREST convention.

Updating a host later: `git submodule update --remote claude-ui && claude-ui/sql/apply.sh`.

## Host contract

**Web.** Mount the component from any SvelteKit route and hand it three things:

```svelte
<script>
  import ClaudePage from "$claude-ui/ClaudePage.svelte";   // kit.alias -> claude-ui/web
  import { isAdmin, getToken } from "$lib/auth";
  import { PGRST } from "$lib/api";
</script>
<ClaudePage pgrst={PGRST} {getToken} {isAdmin} />
```

- `pgrst` — PostgREST base URL serving the `api` schema.
- `getToken()` — returns the viewer's JWT (the page sends `Authorization: Bearer`).
- `isAdmin()` — client-side predicate only; the server-side gate is the `api.claude_*` objects, which
  evaluate the `@ADMIN@` expression you rendered (`CLAUDE_UI_ADMIN_FN`, default `<schema>.is_admin()`).

In `svelte.config.js`: `kit.alias = { '$claude-ui': '../claude-ui/web' }`, and in `vite.config.js`
add `../claude-ui` to `server.fs.allow` if `fs.strict` is on.

**Database.** `sql/apply.sh` creates, in your data schema (`@SCHEMA@`): `claude_msg` (the
conversation, both directions, keyed to transcript uuids for dedup), `claude_ctl` (interrupt commands),
`claude_status` (working/waiting); and in `api`: the `claude_msg` / `claude_status` views and the
`claude_send` / `claude_ctl` RPCs. A dedicated `claude_ui` schema served as its own PostgREST profile
would be the fully standalone shape.

**Relay.** Run under a re-exec loop (one pass per process, so edits are live on the next pass):

```
while true; do python3 claude-ui/relay/claude_voice_relay.py || notify "voice-relay FAILED"; sleep 10; done
```

Environment: `CLAUDE_VOICE_TRANSCRIPT` (the session's `.jsonl` transcript), `CLAUDE_VOICE_PANE`
(tmux target of the `claude` pane; auto-detected when unset), `CLAUDE_VOICE_POLL` (seconds, default
2), `CLAUDE_UI_PG` / `DBURI` (DSN). The relay **exits non-zero on any infrastructure
error** — a dead DB connection must restart the process, not be retried in place.

## Conventions the page relies on

- A URL is autolinked only when it sits **alone on its own line**; put links on their own line.
- A reply may end with `@@suggest: <text>`; the relay strips it and the page shows it as a one-tap
  suggested reply.
- Voice commands are whole-utterance only ("send" sends; "send the summary" is text), matched on the
  final speech result.
