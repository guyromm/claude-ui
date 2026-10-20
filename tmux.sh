#!/bin/bash
# claude-ui worker registry + notifier. SOURCE this from the host's tmux.sh after it has defined
# DIR (host root), PYBIN and the WORKERS / WORKER_WINDOWS associative arrays; it registers claude-ui's
# workers into them so the host's `start <name>` / `all` / watchdog handle them without knowing what
# they are. Standalone use: CUI_HOST_DIR=<host root> bash -c 'source claude-ui/tmux.sh; cui_workers'.
CUI_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
CUI_HOST_DIR="${CUI_HOST_DIR:-${DIR:-$(dirname "$CUI_DIR")}}"
CUI_PY="${PYBIN:-python3}"
declare -A WORKERS WORKER_WINDOWS 2>/dev/null || true

# voice-relay: the two-way bridge for the phone UI. OUT mirrors the claude session's transcript into
# claude_msg; IN send-keys phone messages into the claude pane; CTL delivers interrupts. Pinned to a
# session by .voice_env in the host root (CLAUDE_VOICE_TRANSCRIPT / CLAUDE_VOICE_PANE). One pass per
# exec (the loop IS the hot reload); exits non-zero on any infrastructure failure, and says so.
WORKERS[voice-relay]="bash -c 'cd $CUI_HOST_DIR; set -a; [ -f .env ] && source .env; set +a; [ -f .voice_env ] && source .voice_env; export CLAUDE_UI_HOST_DIR=$CUI_HOST_DIR CLAUDE_UI_SCHEMA=\${CLAUDE_UI_SCHEMA:-public}; trap : INT; while true; do date; $CUI_PY $CUI_DIR/relay/claude_voice_relay.py || (source $CUI_DIR/tmux.sh; notify_claude \"voice-relay FAILED\"); echo restarting in 10s; sleep 10; done'"
WORKER_WINDOWS[voice-relay]=process

# every worker claude-ui registers, for hosts that want to start/stop them as a group
cui_workers() { echo voice-relay; }

# notify_claude "<message>": type "NOTIFY: <message>" into the running claude pane (deduped, fail-open)
notify_claude() { bash "$CUI_DIR/bin/notify_claude.sh" "$@"; }
export -f notify_claude 2>/dev/null
