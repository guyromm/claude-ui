#!/usr/bin/env python3
"""Voice-bridge relay. Two independent loops in one process:

  OUT: tail the Claude Code session TRANSCRIPT (JSONL) and mirror each new ASSISTANT text message
       into claude_msg(direction='out'). Structured, robust -- never scrapes the TUI. Dedup by
       the transcript message uuid (unique index), so restarts and re-reads never double-post.

  IN:  poll claude_msg(direction='in', NOT delivered) and deliver each to the target claude
       tmux pane with `tmux send-keys` (literal body, then Enter), then mark delivered.

This session (the background bg-pty-host job) is NOT a tmux pane, so IN targets a configurable
INTERACTIVE claude pane: CLAUDE_VOICE_PANE (default the newest pane whose command is 'claude').
OUT targets the transcript of whatever session you point CLAUDE_VOICE_TRANSCRIPT at (default: the
most-recently-modified *.jsonl in the project dir -- i.e. the active conversation).

Env:
  CLAUDE_VOICE_PANE        tmux target for send-keys (e.g. %20). Default: auto-detect a 'claude' pane.
  CLAUDE_VOICE_TRANSCRIPT  path to the transcript JSONL. Default: newest .jsonl in the project dir.
  CLAUDE_VOICE_POLL        seconds between IN polls (default 2).
"""
import glob
import json
import os
import subprocess
import datetime as dt
import time

import db as pg   # claude-ui/relay/db.py: the relay's own DB access, no host import

# Claude Code keeps one transcript dir per project, named after the project path with '/' -> '-'.
# Derived from CLAUDE_UI_HOST_DIR (the host project root; the worker runs with cwd there), so the
# same relay serves any project. Override the whole path with CLAUDE_VOICE_TRANSCRIPT to pin a session.
_HOST = os.path.abspath(os.environ.get("CLAUDE_UI_HOST_DIR") or os.getcwd())
PROJ_DIR = os.path.expanduser("~/.claude/projects/" + _HOST.replace("/", "-"))
POLL = float(os.environ.get("CLAUDE_VOICE_POLL", "2"))


def detect_pane():
    """Same resolution as tmux.sh notify_claude: the pane whose TTY actually runs a 'claude' process.
    That pane is the interactive TUI front-end attached to THIS bg session, so send-keys to it lands
    as a real user turn (exactly how NOTIFY: messages arrive). Matching on pane_current_command alone
    is less reliable, so we check the tty's process like notify_claude does."""
    p = os.environ.get("CLAUDE_VOICE_PANE")
    if p:
        return p
    try:
        out = subprocess.run(["tmux", "list-panes", "-a", "-F", "#{pane_id} #{pane_tty}"],
                             capture_output=True, text=True, timeout=10).stdout
        for ln in out.splitlines():
            parts = ln.split()
            if len(parts) < 2:
                continue
            pane, tty = parts[0], parts[1].replace("/dev/", "")
            comm = subprocess.run(["ps", "-t", tty, "-o", "comm="], capture_output=True, text=True, timeout=10).stdout
            if any(c.strip() == "claude" for c in comm.splitlines()):
                return pane
    except Exception:
        pass
    return None


def pane_session_transcript():
    """The transcript of the claude process running IN THE PANE we deliver to -- read from Claude
    Code's own pid registry (~/.claude/sessions/<pid>.json -> sessionId). This is the only resolution
    that follows the session across a /model switch or a --continue restart, both of which start a NEW
    <session>.jsonl in the same pane. A pinned path goes stale exactly that way: /model rotates the session to
    a new id, the pin still names the old one, and the phone keeps showing a stale last reply while
    every newer answer is never mirrored.
    Newest-mtime is no better: other sessions in the same project dir write too (b9d394fb, 11:09).
    Returns None when it cannot tell (no pane, no claude on its tty, no registry file)."""
    pane = detect_pane()
    if not pane:
        return None
    tty = subprocess.run(["tmux", "display", "-p", "-t", pane, "#{pane_tty}"],
                         capture_output=True, text=True, timeout=10).stdout.strip().replace("/dev/", "")
    if not tty:
        return None
    ps = subprocess.run(["ps", "-t", tty, "-o", "pid=,comm="], capture_output=True, text=True, timeout=10).stdout
    for ln in ps.splitlines():
        parts = ln.split()
        if len(parts) == 2 and parts[1] == "claude":
            reg = os.path.expanduser(f"~/.claude/sessions/{parts[0]}.json")
            if os.path.exists(reg):
                sid = json.load(open(reg)).get("sessionId")
                if sid:
                    return os.path.join(PROJ_DIR, sid + ".jsonl")
    return None


def detect_transcript():
    p = os.environ.get("CLAUDE_VOICE_TRANSCRIPT")
    if p:
        return p
    p = pane_session_transcript()
    if p and os.path.exists(p):
        return p
    files = glob.glob(os.path.join(PROJ_DIR, "*.jsonl"))
    return max(files, key=os.path.getmtime) if files else None


import re as _re

def sys_summary(text):
    """If a user-role turn is actually a harness TASK NOTIFICATION (not a human message), return a
    clean one-line summary to show as a NEUTRAL 'sys' bubble; else None. Background-task events arrive
    in the transcript as user turns whose text is a <task-notification> block -- rendering them as the
    user's own words is wrong. We keep only the human-readable <summary>, dropping the ids/paths."""
    if "<task-notification>" not in text and "SYSTEM NOTIFICATION" not in text:
        return None
    sums = _re.findall(r"<summary>(.*?)</summary>", text, _re.S)
    if sums:
        return "  ".join(s.strip() for s in sums)
    st = _re.search(r"<status>(.*?)</status>", text, _re.S)
    return f"background task {st.group(1).strip()}" if st else "background task update"


def split_suggest(text):
    """Pull an optional suggested-next-prompt marker out of an assistant message. Convention: a line
    `@@suggest: <text>` (usually the last line). Returns (clean_body_without_the_marker, suggestion|None)
    so the phone UI can offer it as a Tab-to-accept prompt without the marker showing in the bubble."""
    hits = _re.findall(r"(?m)^@@suggest:[ \t]*(.+?)[ \t]*$", text)
    if not hits:
        return text, None
    suggestion = hits[-1].strip()   # LAST marker wins (a message may carry more than one)
    clean = _re.sub(r"(?m)^@@suggest:[ \t]*.+?[ \t]*$\n?", "", text).strip()   # strip ALL markers
    return clean, (suggestion or None)


def transcript_msg(rec):
    """(direction, text, uuid) for a transcript record that carries user-facing text -- BOTH the
    assistant's replies AND the user's turns (so the phone shows CLI-typed messages too). Returns
    (None, '', None) for tool-only turns (tool_use / tool_result blocks with no text). direction is
    'out' for assistant, 'in' for a human user turn, and 'sys' for a harness task-notification (shown
    as a neutral bubble, never as the user's message and never re-delivered by the IN loop)."""
    t = rec.get("type")
    if t not in ("assistant", "user"):
        return None, "", None
    msg = rec.get("message", {})
    role = msg.get("role")
    if role not in ("assistant", "user"):
        return None, "", None
    uuid = rec.get("uuid") or msg.get("id")
    content = msg.get("content")
    parts = []
    if isinstance(content, str):
        parts.append(content)
    elif isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                parts.append(b.get("text", ""))
    text = "\n".join(p for p in parts if p).strip()
    if role == "user":
        s = sys_summary(text)
        if s is not None:
            return "sys", s, uuid
    return ("out" if role == "assistant" else "in"), text, uuid


def turn_state(rec):
    """WORKING or WAITING, from ONE transcript record. None = record says nothing about state.

    THE RECORD TYPE IS THE SIGNAL, NOT FILE ACTIVITY. A long tool call writes nothing to the
    transcript for minutes while the session is very much working, so any mtime/idle-timeout scheme
    reports "waiting" in the middle of a 10-minute command -- worse than no indicator, because the
    user acts on it. A turn is over only when the assistant's last content has NO tool_use: anything
    else (a user turn just arrived, a tool was called, a tool returned) means work is in flight."""
    t = rec.get("type")
    if t == "user":
        # A tool_result arrives as a 'user' record too -- that is the harness handing a tool's output
        # back mid-turn, not the human speaking. Either way the session has work to do next.
        return "working"
    if t != "assistant":
        return None
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, list) and any(
            isinstance(b, dict) and b.get("type") == "tool_use" for b in content):
        return "working"                       # called a tool; the turn continues
    return "waiting"                           # text with nothing pending: the ball is with the user


# A turn's records alternate assistant-text / tool_use / tool_result, so a text-only block mid-turn
# looks momentarily like "waiting" and the indicator flapped every few seconds, resetting its age to
# 0s and never showing how long a turn had actually been running . WORKING is
# committed immediately -- being told work started late is bad. WAITING is committed only after the
# transcript has been quiet for this long, so an inter-tool pause cannot end the turn on paper.
WAIT_DEBOUNCE_S = float(os.environ.get("CLAUDE_WAIT_DEBOUNCE_S", "20"))
_pend = {"state": None, "since": None}          # a waiting transition that has not settled yet


def _fmt(sec):
    sec = int(sec)
    if sec < 60:  return f"{sec}s"
    if sec < 3600: return f"{sec//60}m {sec%60:02d}s"
    return f"{sec//3600}h {(sec%3600)//60:02d}m"


def settle_state(con):
    """Commit a debounced WAITING, and log how long the turn churned.

    The elapsed time is written into the conversation as a 'sys' row so it stays with the exchange it
    belongs to -- the header pill shows only the live state, and the user asked to see, in context,
    how long each answer took. A record, not a readout."""
    if _pend["state"] != "waiting" or _pend["since"] is None:
        return
    if (time.time() - _pend["since"]) < WAIT_DEBOUNCE_S:
        return
    row = pg.q1("SELECT state, since FROM claude_status WHERE singleton")
    if row and row["state"] == "working":
        worked = (dt.datetime.now(dt.timezone.utc) - row["since"]).total_seconds()
        con.execute("""INSERT INTO claude_msg(direction, body, delivered, src_uuid)
                       VALUES ('sys', %s, true, %s)""",
                    (f"⏱ churned {_fmt(worked)}", f"churn-{int(time.time())}"))
    set_state(con, "waiting")
    _pend["state"] = None


def set_state(con, state, detail=None):
    """Upsert, moving `since` ONLY when the state actually changes, so the UI can say how long."""
    con.execute("""INSERT INTO claude_status(singleton, state, detail, since, ts)
                   VALUES (true, %s, %s, now(), now())
                   ON CONFLICT (singleton) DO UPDATE
                     SET state  = EXCLUDED.state,
                         detail = EXCLUDED.detail,
                         since  = CASE WHEN claude_status.state = EXCLUDED.state
                                       THEN claude_status.since ELSE now() END,
                         ts     = now()""", (state, detail))


def session_pid():
    """The claude APP pid for the session we are bridging (NOT the bg-pty-host). Derived from the
    transcript filename (<session>.jsonl) so nothing is hardcoded."""
    path = detect_transcript()
    if not path:
        return None
    sid = os.path.basename(path)[:-6]   # strip .jsonl
    try:
        out = subprocess.run(["pgrep", "-f", f"session-id {sid}"], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return None
    for pid in out.split():
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                cmd = fh.read().replace(b"\0", b" ").decode(errors="ignore")
            if "bg-pty-host" not in cmd and "session-id" in cmd:
                return int(pid)
        except Exception:
            continue
    return None


def ctl_loop(con):
    """Emergency control: deliver SIGINT to the session's claude pid. int=once (interrupt current
    turn, the ESC equivalent for a bg session), int2=twice ~150ms apart (harder Ctrl-C)."""
    import signal
    print("CTL: polling claude_ctl", flush=True)
    while True:
        try:
            rows = con.execute(
                "SELECT id, cmd FROM claude_ctl WHERE NOT delivered ORDER BY id").fetchall()
            for cid, cmd in rows:
                pid = session_pid()
                if pid:
                    try:
                        os.kill(pid, signal.SIGINT)
                        if cmd == "int2":
                            time.sleep(0.15); os.kill(pid, signal.SIGINT)
                        print(f"CTL: {cmd} -> SIGINT pid {pid}", flush=True)
                    except Exception as e:
                        print(f"CTL: signal failed: {e}", flush=True)
                else:
                    print("CTL: no session pid found", flush=True)
                con.execute("UPDATE claude_ctl SET delivered=true WHERE id=%s", (cid,))
        except Exception as e:
            # DIE. Do NOT catch-and-continue: this exact handler swallowed
            # "OperationalError: the connection is closed" on every poll for hours
            # after postgres was restarted, while the process stayed alive and the phone UI silently
            # stopped updating. A relay that keeps looping over a dead connection is worse than one
            # that exits: the tmux wrapper restarts it in seconds AND fires notify_claude, so a crash
            # is visible and self-healing where a swallowed error is neither.
            print(f"CTL: FATAL {type(e).__name__}: {e}", flush=True)
            os._exit(1)
        time.sleep(1)


def out_loop(con):
    """Cursor by file byte offset AND uuid dedup (the unique index is the real guard)."""
    path = detect_transcript()
    if not path:
        print("OUT: no transcript found", flush=True)
        return
    print(f"OUT: tailing {path}", flush=True)
    # START AT ZERO, NOT AT EOF. The INSERT below dedups on src_uuid (ON CONFLICT DO NOTHING), so a
    # full re-read is idempotent -- it inserts only turns the DB is missing and costs one scan.
    # Starting at EOF meant every restart silently DROPPED whatever happened while the relay was down.
    # Seen in practice: postgres was restarted administratively, the relay's connection died, and it
    # spent 5.5 hours logging "connection is closed" on every poll; when it was restarted the phone UI
    # still showed nothing newer than 01:47, because the gap was skipped rather than backfilled. A
    # relay that loses exactly the window it was broken for is the worst possible behaviour: the user
    # cannot tell "nothing happened" from "I missed it".
    offset = 0
    while True:
        try:
            # re-detect in case the active conversation rotated to a new file
            newp = detect_transcript()
            if newp != path:
                path, offset = newp, 0
            size = os.path.getsize(path)
            if size < offset:          # file truncated/rotated
                offset = 0
            if size > offset:
                with open(path, "r") as fh:
                    fh.seek(offset)
                    chunk = fh.read()
                    offset = fh.tell()
                for line in chunk.splitlines():
                    if not line.strip():
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    st = turn_state(rec)
                    if st == "working":
                        _pend["state"] = None       # any activity cancels a pending settle
                        set_state(con, "working")
                    elif st == "waiting" and _pend["state"] != "waiting":
                        _pend["state"], _pend["since"] = "waiting", time.time()
                    direction, text, uuid = transcript_msg(rec)
                    suggest = None
                    if direction == "out":
                        text, suggest = split_suggest(text)   # pull @@suggest: off the assistant turn
                    if direction and text and uuid:
                        # A user turn the PAGE sent already has a row (direction='in', src_uuid NULL,
                        # delivered by the IN loop). Mirroring its transcript echo inserted it a SECOND
                        # time. Claim that row instead: attach this uuid to the newest recent delivered
                        # page row whose body matches (exactly, or as the tail of the transcript text --
                        # a stray char already in the pane's input can prefix it, e.g. "c" + "ok, ...").
                        if direction == "in":
                            claimed = con.execute(
                                """UPDATE claude_msg SET src_uuid = %s
                                    WHERE id = (SELECT id FROM claude_msg
                                                 WHERE direction = 'in' AND src_uuid IS NULL AND delivered
                                                   AND ts > now() - interval '10 minutes'
                                                   AND (body = %s OR right(%s, length(body)) = body)
                                                 ORDER BY id DESC LIMIT 1)
                                      -- the relay REPLAYS the transcript from offset 0 on restart: a turn
                                      -- already mirrored must not be claimed again (unique src_uuid).
                                      AND NOT EXISTS (SELECT 1 FROM claude_msg WHERE src_uuid = %s)""",
                                (uuid, text.strip(), text.strip(), uuid)).rowcount
                            if claimed:
                                continue
                        # src_uuid keys the row to the transcript turn (dedup). delivered=true means
                        # the IN loop never tries to re-send these -- they ALREADY happened. The IN
                        # loop only send-keys the phone's fresh delivery rows (src_uuid IS NULL).
                        con.execute(
                            """INSERT INTO claude_msg(direction, body, delivered, src_uuid, suggest)
                               VALUES(%s, %s, true, %s, %s) ON CONFLICT (src_uuid) DO NOTHING""",
                            (direction, text, uuid, suggest))
        except Exception as e:
            # DIE. Do NOT catch-and-continue: this exact handler swallowed
            # "OperationalError: the connection is closed" on every poll for hours
            # after postgres was restarted, while the process stayed alive and the phone UI silently
            # stopped updating. A relay that keeps looping over a dead connection is worse than one
            # that exits: the tmux wrapper restarts it in seconds AND fires notify_claude, so a crash
            # is visible and self-healing where a swallowed error is neither.
            print(f"OUT: FATAL {type(e).__name__}: {e}", flush=True)
            os._exit(1)
        # SETTLE ON EVERY POLL, not only when a record arrives. The last record of a turn is the
        # assistant's final text; if nothing follows, no further iteration would ever commit the
        # WAITING transition and the indicator would sit on "working" forever.
        settle_state(con)
        time.sleep(1)


def send_to_pane(pane, body):
    # collapse newlines (a bare newline would submit early in the TUI), send the text literally, then
    # a separate Enter to submit -- same two-step notify_claude uses.
    body = " ".join(body.split())
    # CHUNKED: one send-keys per <=4000 chars. tmux rejects a single oversized command ("command too
    # long", ~16 KB imsg limit) -- a 35 KB paste once hit that on every poll for days.
    for i in range(0, len(body), 4000):
        subprocess.run(["tmux", "send-keys", "-t", pane, "-l", body[i:i + 4000]], timeout=10, check=True)
    time.sleep(0.2)
    subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"], timeout=10, check=True)


def in_loop(con):
    print("IN: polling claude_msg for phone messages", flush=True)
    while True:
        try:
            # ONLY the phone's fresh delivery rows: direction='in', not yet send-keys'd, and NOT a
            # transcript mirror (src_uuid IS NULL). Transcript-mirrored turns already happened.
            rows = con.execute(
                "SELECT id, body FROM claude_msg WHERE direction='in' AND NOT delivered AND src_uuid IS NULL"
                " AND fail_reason IS NULL ORDER BY id"
            ).fetchall()
            if rows:
                pane = detect_pane()
                if not pane:
                    print("IN: no target claude pane; leaving messages queued", flush=True)
                else:
                    for mid, body in rows:
                        try:
                            send_to_pane(pane, body)
                            con.execute("UPDATE claude_msg SET delivered=true WHERE id=%s", (mid,))
                            print(f"IN: delivered #{mid} -> {pane}", flush=True)
                        except Exception as e:
                            # PER-ITEM failure: PARK the row (fail_reason, visible, re-queued by clearing it)
                            # and go on to the next. `break` here head-of-line blocked every later
                            # message behind one undeliverable paste from 09-16 to 09-19. The pane itself
                            # being gone is caught above by detect_pane(), so this is the message's fault.
                            print(f"IN: send #{mid} failed, parked: {e}", flush=True)
                            con.execute("UPDATE claude_msg SET fail_reason=%s WHERE id=%s", (str(e)[:500], mid))
        except Exception as e:
            # DIE. Do NOT catch-and-continue: this exact handler swallowed
            # "OperationalError: the connection is closed" on every poll for hours
            # after postgres was restarted, while the process stayed alive and the phone UI silently
            # stopped updating. A relay that keeps looping over a dead connection is worse than one
            # that exits: the tmux wrapper restarts it in seconds AND fires notify_claude, so a crash
            # is visible and self-healing where a swallowed error is neither.
            print(f"IN: FATAL {type(e).__name__}: {e}", flush=True)
            os._exit(1)
        time.sleep(POLL)


def main():
    # OUT is always run (mirror assistant transcript -> DB for the phone). IN (send-keys to a pane)
    # is for driving a SEPARATE interactive claude pane; the CURRENT bg-pty-host session cannot be
    # send-keys'd, so it self-delivers via a background monitor instead -> set CLAUDE_VOICE_NO_IN=1.
    import threading
    con_out = pg.connect(autocommit=True)
    con_ctl = pg.connect(autocommit=True)
    threading.Thread(target=ctl_loop, args=(con_ctl,), daemon=True).start()   # emergency stop, always on
    if os.environ.get("CLAUDE_VOICE_NO_IN") == "1":
        print("IN loop disabled (current-session mode: input arrives via the session's own monitor)", flush=True)
        out_loop(con_out)
    else:
        con_in = pg.connect(autocommit=True)
        threading.Thread(target=out_loop, args=(con_out,), daemon=True).start()
        in_loop(con_in)


if __name__ == "__main__":
    main()
