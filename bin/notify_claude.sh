#!/bin/bash
# notify_claude "<message>" -- type "NOTIFY: <message>" into the running `claude` tmux pane.
# Standalone copy of the host's tmux.sh function so any project (or cron) can alert the session.
# Dedups identical alerts within NOTIFY_DEDUP_S (default 3600) via a tmpfs stamp; fail-open.
_notify_claude() {
    local message="$*"; [ -z "$message" ] && return 1
    # DEDUP: an IDENTICAL alert inside NOTIFY_DEDUP_S (default 900) is suppressed. One dependency
    # failing (e.g. postgres down) makes ~40 workers each alert every cycle, and the flood
    # buries the real signal instead of carrying it -- the first occurrence of each distinct message
    # still always goes through, so nothing is lost, it just stops repeating every 60s.
    # FAIL-OPEN by construction: any problem reading/writing the stamp falls through to sending.
    # State is a tmpfs stamp, not a DB row, precisely because the DB is what tends to be down here.
    local _w="${NOTIFY_DEDUP_S:-3600}" _d="${TMPDIR:-/tmp}/claude-notify-$(id -u)" _k _now _last
    _k=$(printf '%s' "$message" | md5sum 2>/dev/null | cut -d' ' -f1)
    if [ -n "$_k" ] && mkdir -p "$_d" 2>/dev/null; then
        _now=$(date +%s); _last=$(cat "$_d/$_k" 2>/dev/null)
        case "$_last" in ''|*[!0-9]*) _last=0;; esac
        if [ "$_last" -gt 0 ] && [ $((_now - _last)) -lt "$_w" ]; then return 0; fi
        printf '%s' "$_now" > "$_d/$_k" 2>/dev/null
    fi
    local cpane="" tty
    while IFS=' ' read -r spec tty; do
        ps -t "${tty#/dev/}" -o comm= 2>/dev/null | grep -q '^claude$' && { cpane="$spec"; break; }
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}")
    [ -z "$cpane" ] && { echo "no claude pane"; return 1; }
    ( sleep 0.3; tmux send-keys -t "$cpane" "NOTIFY: $message"; sleep 0.2; tmux send-keys -t "$cpane" Enter ) & disown
}
_notify_claude "$@"
