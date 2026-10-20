<script>
  // VOICE BRIDGE: hands-free two-way chat with a running Claude Code session, for use
  // on the go. OUT = assistant messages the relay mirrors from the session transcript into
  // <schema>.claude_msg; we poll api.claude_msg, render markdown->HTML, and optionally read each new one
  // aloud. IN = phone speech-to-text -> api.claude_send -> the session's own monitor delivers it.
  //
  // TTS is the browser's built-in speechSynthesis for now (zero deps). speak() is the ONE swappable
  // point: a local Kokoro-82M (kokoro-js/transformers.js) can replace it later -- deferred because an
  // npm add under the live vite dev server breaks the site (CLAUDE.md), so Kokoro needs self-hosted
  // weights + optimizeDeps wiring first. STT is webkitSpeechRecognition (Chrome/Android).
  import { onMount, onDestroy, afterUpdate } from "svelte";
  // HOST CONTRACT. This component is project-agnostic: the host route passes its PostgREST base URL,
  // its JWT getter and its admin predicate. Nothing in here imports from the host's $lib.
  export let pgrst;          // e.g. "https://api.example.com"
  export let getToken;       // () => JWT string (or null)
  export let isAdmin;        // () => boolean

  let ready = false, admin = false, err = "";
  // TRUE until the first message fetch settles. Without it the page rendered "No messages yet"
  // for the whole load -- and on a phone that is ~15s, because vite dev serves the route as
  // hundreds of separate ES modules and Cache-Control: no-store (required, it is what stops
  // Cloudflare serving a stale module mix) makes the browser re-fetch all of them every time.
  // The server is not slow: HTML 5ms, API 16ms, payload 16kB. Saying "empty" while still
  // loading is a lie the user has to wait 15 seconds to see corrected.
  let loadingMsgs = true;
  let msgs = [];          // {id, direction, body, ts}
  let lastId = 0;
  let autoRead = true;    // speak new assistant messages automatically
  let listening = false;  // mic on
  let interim = "";       // live STT transcript
  let draft = "";         // editable text before send
  let sttBase = "";       // committed text the current utterance appends to (hoisted so Clear can reset it)
  let undoStack = [];     // draft snapshots before each committed utterance / clear -- "scratch that" pops
  let cmdFlash = "";      // one-word confirmation of the last voice command, shown in the placeholder
  // compact age, so "working 12m" reads at a glance without a clock in the header
  function ago(t) {
    const sec = Math.max(0, (Date.now() - new Date(t).getTime()) / 1000);
    if (sec < 60) return `${sec | 0}s`;
    if (sec < 3600) return `${(sec / 60) | 0}m`;
    return `${(sec / 3600) | 0}h`;
  }
  let followOwn = false;   // one-shot: scroll for the message the user just sent
  // TICK for the live churn counter. The busy state itself only refreshes on the 2s poll; without a
  // local clock the elapsed time would jump in 2s steps and look frozen between polls.
  let nowMs = Date.now();
  setInterval(() => { nowMs = Date.now(); }, 1000);
  // elapsed churn, formatted the same way the relay formats the permanent record, so the live
  // counter and the system message it turns into read identically.
  function churn(sinceIso) {
    const sec = Math.max(0, (nowMs - new Date(sinceIso).getTime()) / 1000) | 0;
    if (sec < 60) return `${sec}s`;
    if (sec < 3600) return `${(sec/60)|0}m ${String(sec%60).padStart(2,"0")}s`;
    return `${(sec/3600)|0}h ${String(((sec%3600)/60)|0).padStart(2,"0")}m`;
  }
  let busy = null;          // "working" | "waiting" | null (unknown yet)
  let busySince = null;
  let suggestion = "";    // Claude's suggested next prompt (@@suggest: on its turn); Tab accepts it
  let poll = null, rec = null;
  let el;                 // scroll container
  // UNREAD COUNTER INSTEAD OF AUTOSCROLL ("do not touch the viewport").
  // Being yanked to the bottom mid-read every time an alert lands is hostile, and with NOTIFY
  // arriving every few minutes it made the log unreadable. Count what is below the viewport and
  // let the reader choose when to go there.
  let unseen = 0;
  function countUnseen() {
    if (!el) return;
    const slack = 80;                       // "almost at the bottom" counts as at the bottom
    if (el.scrollHeight - el.scrollTop - el.clientHeight <= slack) { unseen = 0; return; }
    const cut = el.scrollTop + el.clientHeight;
    let n = 0;
    for (const node of el.querySelectorAll(".m")) if (node.offsetTop > cut) n++;
    unseen = n;
  }
  function toBottom() { el?.scrollTo({ top: el.scrollHeight, behavior: "smooth" }); unseen = 0; }
  let taEl;               // the input textarea (auto-scroll to show the growing end)
  // IMPERATIVE scroll (a reactive `$: if (taEl…)` here crashed hydration on mobile -- it fires the
  // moment the textarea binds and something about the scheduled DOM write aborted the route hydrate,
  // leaving the page stuck on "…"). Call this after setting draft instead.
  const scrollTa = () => queueMicrotask(() => { if (taEl) taEl.scrollTop = taEl.scrollHeight; });

  // ---------- minimal, XSS-safe markdown -> HTML (no library: an npm add breaks vite) ----------
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  // USER messages are NOT run through full markdown -- they are literal text and always have been.
  // But a quoted reply must LOOK quoted, so this renders '> ' runs as blockquotes
  // and escapes the rest verbatim. Deliberately narrow: no links, no code, no emphasis, so nothing a
  // user types is silently reinterpreted.
  function mdQuote(src) {
    const out = [];
    let buf = [], quoting = false;
    const flush = () => {
      if (!buf.length) return;
      out.push(quoting ? "<blockquote>" + buf.join("\n") + "</blockquote>" : buf.join("\n"));
      buf = [];
    };
    for (const line of esc(src || "").split("\n")) {
      const isQ = /^&gt;\s?/.test(line);
      if (isQ !== quoting) { flush(); quoting = isQ; }
      buf.push(isQ ? line.replace(/^&gt;\s?/, "") : line);
    }
    flush();
    return out.join("\n");
  }

  function md(src) {
    const blocks = [];
    let s = esc(src || "");
    s = s.replace(/```(\w*)\n?([\s\S]*?)```/g, (_, l, c) => { blocks.push(`<pre><code>${c.replace(/\n$/, "")}</code></pre>`); return `@@BLK${blocks.length - 1}@@`; });
    s = s.replace(/`([^`\n]+)`/g, "<code>$1</code>");
    // INLINE IMAGES stored in the DB (claude_img; posted with bin/cui-img): ![caption](cui-img:<uuid>).
    // Rendered as a src-less placeholder; loadImages() fills it via PostgREST with the user's token, so the
    // image never needs a public URL. The alt text is already escaped; the id is strictly a uuid.
    s = s.replace(/!\[([^\]]*)\]\(cui-img:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\)/g,
                  '<img class="cui-img" data-cui-img="$2" alt="$1" title="$1">');
    // BLOCKQUOTES. Runs of '> ' lines become one <blockquote>, like email. Matched AFTER esc(), which
    // has already turned '>' into '&gt;' -- matching the raw '>' here would never fire.
    s = s.replace(/(^|\n)((?:&gt;[^\n]*(?:\n|$))+)/g, (_m, pre, blk) =>
      pre + "<blockquote>" +
      blk.replace(/\n$/, "").split("\n").map((l) => l.replace(/^&gt;\s?/, "")).join("\n") +
      "</blockquote>");
    s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
    // Autolink BARE urls (we post them on their own line, not as [text](url)). The leading boundary
    // (start | whitespace | '(') means a url already inside href="..." (preceded by '"') or as anchor
    // text (preceded by '>') is NOT re-matched, so this is safe to run after the markdown-link pass.
    // Trailing sentence punctuation is left outside the link.
    s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)]+[^\s<).,;:!?])/g,
                  '$1<a href="$2" target="_blank" rel="noopener">$2</a>');
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");
    // GH-style tables: a header row, a |---|---| separator, then body rows. Stash as a block
    // (like code fences) so the line loop below doesn't treat each row as a paragraph.
    const cells = (row) => row.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
    s = s.replace(/(^ *\|.+\| *\n)( *\|[ :|-]+\| *\n)((?: *\|.+\| *\n?)+)/gm, (mm, head, _sep, body) => {
      const th = cells(head).map((c) => `<th>${c}</th>`).join("");
      const rows = body.trimEnd().split("\n").map((r) => "<tr>" + cells(r).map((c) => `<td>${c}</td>`).join("") + "</tr>").join("");
      blocks.push(`<table><thead><tr>${th}</tr></thead><tbody>${rows}</tbody></table>`);
      return `@@BLK${blocks.length - 1}@@`;
    });
    // line-oriented: headings, list items, paragraphs
    const out = [];
    let list = null;
    for (const raw of s.split("\n")) {
      const line = raw.replace(/\r$/, "");
      let m;
      if (/^@@BLK\d+@@$/.test(line.trim())) { if (list) { out.push(`</${list}>`); list = null; } out.push(line.trim()); continue; }
      if ((m = line.match(/^(#{1,4})\s+(.*)/))) { if (list) { out.push(`</${list}>`); list = null; } out.push(`<h${m[1].length + 2}>${m[2]}</h${m[1].length + 2}>`); }
      else if ((m = line.match(/^\s*[-*]\s+(.*)/))) { if (list !== "ul") { if (list) out.push(`</${list}>`); out.push("<ul>"); list = "ul"; } out.push(`<li>${m[1]}</li>`); }
      else if ((m = line.match(/^\s*\d+\.\s+(.*)/))) { if (list !== "ol") { if (list) out.push(`</${list}>`); out.push("<ol>"); list = "ol"; } out.push(`<li>${m[1]}</li>`); }
      else if (line.trim() === "") { if (list) { out.push(`</${list}>`); list = null; } }
      else { if (list) { out.push(`</${list}>`); list = null; } out.push(`<p>${line}</p>`); }
    }
    if (list) out.push(`</${list}>`);
    let html = out.join("\n");
    html = html.replace(/@@BLK(\d+)@@/g, (_, i) => blocks[+i]);   // restore code blocks
    return html;
  }
  // strip markdown for the SPOKEN version (don't read "asterisk asterisk")
  const toPlain = (s) => (s || "")
    .replace(/```[\s\S]*?```/g, " code block ")
    .replace(/`([^`]+)`/g, "$1").replace(/\*\*|__|[*_#>]/g, "")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1").replace(/\s+/g, " ").trim();

  // ---------- TTS (swap here for Kokoro later) ----------
  function speak(text) {
    try {
      if (!("speechSynthesis" in window)) return;
      const u = new SpeechSynthesisUtterance(toPlain(text));
      u.rate = 1.05; u.pitch = 1;
      window.speechSynthesis.cancel();
      window.speechSynthesis.speak(u);
    } catch {}
  }
  const stopSpeaking = () => { try { window.speechSynthesis?.cancel(); } catch {} };

  // emergency control: SIGINT to the session (int = interrupt/ESC, int2 = Ctrl-C)
  async function ctl(cmd) {
    stopSpeaking();
    try {
      const r = await fetch(`${pgrst}/rpc/claude_ctl`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${getToken()}` },
        body: JSON.stringify({ p_cmd: cmd }) });
      if (!r.ok) err = `ctl ${r.status}`;
    } catch { err = "ctl failed"; }
  }

  // ---------- polling for new assistant messages ----------
  // Fill every not-yet-loaded inline image (see md()). Cached per id for the session.
  const imgCache = new Map();
  async function loadImages() {
    for (const im of document.querySelectorAll("img[data-cui-img]:not([data-loaded])")) {
      const id = im.dataset.cuiImg;
      im.dataset.loaded = "1";
      try {
        let url = imgCache.get(id);
        if (!url) {
          const r = await fetch(`${pgrst}/claude_img?id=eq.${id}&select=mime,b64`,
                                { headers: { Authorization: `Bearer ${getToken()}` } });
          const row = r.ok ? (await r.json())[0] : null;
          if (!row) { im.alt = `[image ${id.slice(0, 8)} unavailable]`; continue; }
          const bin = atob(row.b64); const u8 = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
          url = URL.createObjectURL(new Blob([u8], { type: row.mime }));
          imgCache.set(id, url);
        }
        im.src = url;
        im.onclick = () => window.open(url, "_blank", "noopener");
      } catch { im.dataset.loaded = ""; }
    }
  }
  afterUpdate(loadImages);

  async function fetchNew() {
    try {
      // poll BOTH directions now: the view surfaces assistant replies AND transcript-mirrored user
      // turns (so CLI-typed messages appear here too, not just phone ones). The phone's own send()
      // no longer echoes optimistically -- the message shows when its transcript mirror arrives.
      // NEVER poll from zero. lastId stays 0 until the initial load succeeds, so a failed first
      // fetch turned every subsequent poll into "give me the whole table" -- 12,931 rows each time,
      // which exhausted PostgREST's connection pool and 504'd the entire API. Bounded
      // both ways: a floor when lastId is unset, and a hard limit so this query can never be large.
      const from = lastId || 0;
      const q = from ? `id=gt.${from}&order=id&limit=200`
                     : `order=id.desc&limit=25`;
      const r = await fetch(`${pgrst}/claude_msg?${q}`,
                            { headers: { Authorization: `Bearer ${getToken()}` } });
      if (!r.ok) { err = `poll ${r.status}`; return; }
      // WORKING / WAITING, on the SAME poll -- no extra timer and no extra round trip cadence.
      // Derived by the relay from the last transcript RECORD (a tool call means the turn continues),
      // never from activity timeouts: a long tool call is silent for minutes while work is in flight,
      // and an indicator that says "waiting" then is worse than none because it gets acted on.
      fetch(`${pgrst}/claude_status?select=state,since&limit=1`,
            { headers: { Authorization: `Bearer ${getToken()}` } })
        .then(x => x.ok ? x.json() : null)
        .then(j => { if (j && j.length) { busy = j[0].state; busySince = j[0].since; } })
        .catch(() => {});
      let rows = await r.json();
      if (!from) rows = rows.reverse();     // the desc+limit fallback comes back newest-first
      if (rows.length) {
        err = "";
        for (const m of rows) {
          msgs = [...msgs, m];
          lastId = Math.max(lastId, m.id);
          if (m.direction === "out" && autoRead) speak(m.body);
          if (m.direction === "out" && m.suggest) suggestion = m.suggest;   // freshest suggestion wins
        }
        if (followOwn && rows.some(m => m.direction === "in")) {
          followOwn = false;
          queueMicrotask(toBottom);    // the user's OWN message: show it
        } else {
          queueMicrotask(countUnseen); // someone else's: never scroll, just count what is below
        }
      }
    } catch { err = "poll failed"; }
  }

  // ---------- send ----------
  // drop a suggested prompt into the composer (from the inline message chip, the composer bar, Tab, or
  // the ⇥ button). Focuses the box for editing; never auto-sends.
  // ---------- QUOTE A SELECTION ----------
  // Android shows its OWN selection menu (copy/share) and a web page cannot add entries to it, so this
  // is a small floating button anchored to the selection -- it sits ALONGSIDE the OS menu rather than
  // trying to replace it, so copy still works exactly as before. Tap it and the selected text lands in
  // the composer as a markdown quote with the caret on a fresh line below.
  let quoteBtn = null;           // {x, y, text} | null

  function onSelect() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) { quoteBtn = null; return; }
    const text = sel.toString().trim();
    if (!text) { quoteBtn = null; return; }
    // only inside the CONVERSATION -- not the composer, not the header
    const n = sel.anchorNode;
    const host = n && (n.nodeType === 1 ? n : n.parentElement);
    if (!host || !host.closest || !host.closest(".log")) { quoteBtn = null; return; }
    const r = sel.getRangeAt(0).getBoundingClientRect();
    if (!r || (!r.width && !r.height)) { quoteBtn = null; return; }
    quoteBtn = { x: r.left + r.width / 2, y: r.top, text };
  }

  function quoteSelection() {
    const t = quoteBtn && quoteBtn.text;
    if (!t) return;
    // one '> ' per line so a multi-line selection stays one quote block, then a blank line + caret.
    // APPENDS rather than replaces: quoting twice builds up and an in-progress draft is never lost.
    const quoted = t.split("\n").map((l) => "> " + l).join("\n");
    const sep = draft && !draft.endsWith("\n") ? "\n\n" : "";
    draft = draft + sep + quoted + "\n\n";
    quoteBtn = null;
    try { window.getSelection().removeAllRanges(); } catch {}
    queueMicrotask(() => {
      if (!taEl) return;
      taEl.focus();
      const end = draft.length;            // caret on the empty line BELOW the quote
      taEl.setSelectionRange(end, end);
      taEl.scrollTop = taEl.scrollHeight;
    });
  }

  function useSuggestion(text) {
    if (!text) return;
    draft = text; suggestion = "";
    queueMicrotask(() => taEl && taEl.focus());
  }
  const acceptSuggestion = () => useSuggestion(suggestion);

  async function send(text) {
    const body = (text ?? draft).trim();
    if (!body) return;
    draft = ""; interim = ""; suggestion = "";   // sending moves past the suggestion
    try {
      const r = await fetch(`${pgrst}/rpc/claude_send`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${getToken()}` },
        body: JSON.stringify({ p_body: body }) });
      if (!r.ok) { err = `send ${r.status}`; return; }
      // no optimistic echo: the message appears via its transcript mirror (arrives on the next poll,
      // ~2s), the same single source that also surfaces CLI-typed messages. Avoids a double render.
      // ...but FOLLOW YOUR OWN MESSAGE DOWN. "Do not jerk the viewport" is about
      // Claude's replies arriving while you read something else -- it was never meant to hide the
      // message YOU just sent. Combined with the no-echo delay that is exactly what it did: the text
      // vanished from the composer and appeared 2s later below the fold, so a sent message looked
      // lost. Arm a one-shot: the next poll that carries an inbound row scrolls.
      followOwn = true;
    } catch { err = "send failed"; }
  }

  const clearDraft = () => {
    // Zero the draft AND the STT accumulator, then flush the running recognition. Without resetting
    // sttBase (the committed-text base the in-flight utterance appends to) and aborting, the next
    // onresult rebuilds draft = sttBase + phrase and resurrects the just-cleared text. abort() (not
    // stop()) discards the current audio+results; onend then restarts if still listening, and the new
    // onstart recomputes sttBase from the now-empty draft.
    if (draft) undoStack = [...undoStack.slice(-9), draft];   // "undo" / "scratch that" brings it back
    draft = ""; interim = ""; sttBase = "";
    if (rec) { try { rec.abort(); } catch {} }
    scrollTa();
  };

  // ---------- VOICE COMMANDS ----------
  // The convention every mature dictation system converged on (Dragon, Apple/Siri, Gboard, Windows
  // Voice Access): a command is an utterance that is NOTHING BUT the command. "send" alone sends;
  // "send the summary" is text. Matched only on the FINAL result of a self-contained utterance
  // (continuous=false gives us exactly that unit), never on interim text, so a half-heard "sen…" can't
  // fire. Vocabulary follows the industry words rather than inventing: "scratch that" is Dragon's
  // undo-last-utterance and is universally understood; "read it back" is Siri's; "new line" /
  // "new paragraph" are Dragon's and Apple's. Deliberately small -- no kitchen sink.
  const CMDS = [
    [/^(send|send it|send message)$/,                  "send",  () => { if (draft.trim()) send(); }],
    [/^(clear|clear all|delete all|delete everything)$/, "cleared", () => clearDraft()],
    [/^(scratch that|undo|undo that)$/,                "undone", () => {
      // pop the draft as it was before the last committed utterance (or before the last clear)
      draft = undoStack.length ? undoStack[undoStack.length - 1] : "";
      undoStack = undoStack.slice(0, -1);
      sttBase = ""; interim = "";
      if (rec) { try { rec.abort(); } catch {} }   // onstart recomputes sttBase from the restored draft
    }],
    [/^(read it back|read back|read that back)$/,      "reading", () => { if (draft.trim()) speak(draft); }],
    [/^(read reply|read the reply|read last|read last reply)$/, "reading", () => {
      const m = [...msgs].reverse().find((x) => x.direction === "out"); if (m) speak(m.body);
    }],
    [/^(stop|stop reading|shut up|quiet)$/,            "stopped", () => stopSpeaking()],
    // Windows Voice Access / Dragon: "stop listening" turns the mic off. Distinct from plain "stop",
    // which only silences TTS -- saying "stop" to interrupt a read-back must not also kill the mic.
    [/^(stop listening|mic off|microphone off)$/,       "mic off", () => { if (listening) toggleMic(); }],
    [/^(new line|newline)$/,                           "newline", () => { draft = draft.replace(/\s+$/, "") + "\n"; }],
    [/^(new paragraph)$/,                              "newline", () => { draft = draft.replace(/\s+$/, "") + "\n\n"; }],
  ];
  function voiceCommand(phrase) {
    const p = phrase.toLowerCase().replace(/[.,!?]+$/g, "").replace(/\s+/g, " ").trim();
    for (const [re, label, fn] of CMDS) {
      if (!re.test(p)) continue;
      draft = sttBase.replace(/\s+$/, "");          // the command word itself never lands in the draft
      interim = "";
      fn();
      // feedback the way phones do it: a short buzz plus a one-word confirmation, no spoken echo --
      // a TTS "sent" would be picked up by the open mic on a speakerphone
      try { navigator.vibrate?.(30); } catch {}
      cmdFlash = label; setTimeout(() => { if (cmdFlash === label) cmdFlash = ""; }, 1500);
      return true;
    }
    return false;
  }

  // TIMESTAMP ON DEMAND: long-press OR swipe-right a message to reveal when it was
  // sent. Not shown by default -- a timestamp on every bubble is noise on a phone -- and not a hover
  // title either, because there is no hover on touch. Tap anywhere / press again to dismiss.
  let tsShown = null;           // claude_msg id whose time is revealed
  let _lp = null, _sx = 0, _sy = 0;
  // NOTIFY lines arrive on the "in" channel (the relay posts them as if the user typed them), so
  // they rendered as ordinary green user bubbles and were indistinguishable from something the
  // user actually said. They are machine-generated alerts routed THROUGH the user channel --
  // a "user system" message -- so they get their own purple treatment: same side as the user,
  // because that is where they come from, but visibly not a human utterance.
  const isNotify = (m) => m.direction === "in" && /^\s*NOTIFY:/.test(m.body || "");
  // the violet already says "this is an alert", so the literal prefix is redundant ink on a
  // narrow phone column. Stripped for DISPLAY only -- claude_msg.body keeps it verbatim, which
  // is what isNotify() and every downstream reader match on.
  const notifyBody = (b) => (b || "").replace(/^\s*NOTIFY:\s*/, "");
  const stamp = (t) => t ? new Date(t).toLocaleString([], { month: "short", day: "numeric",
                            hour: "2-digit", minute: "2-digit", second: "2-digit" }) : "";
  function pressStart(m, e) {
    const t = e.touches ? e.touches[0] : e;
    _sx = t.clientX; _sy = t.clientY;
    clearTimeout(_lp);
    _lp = setTimeout(() => { tsShown = tsShown === m.id ? null : m.id; _lp = null; }, 450);
  }
  function pressMove(m, e) {
    const t = e.touches ? e.touches[0] : e;
    const dx = t.clientX - _sx, dy = t.clientY - _sy;
    // a deliberate rightward swipe reveals it; vertical movement is a scroll and must cancel, or the
    // timestamp would pop up every time the log is scrolled with a finger down on a bubble.
    if (Math.abs(dy) > 12) { clearTimeout(_lp); _lp = null; return; }
    if (dx > 45) { clearTimeout(_lp); _lp = null; tsShown = m.id; }
  }
  const pressEnd = () => { clearTimeout(_lp); _lp = null; };

  // Permalink to a single message: keyed to the immutable claude_msg id (never row order). Copies the
  // #m<id> URL to the clipboard, sets the hash, and flashes the message. flashMsg + the onMount hash
  // handler make a pasted link scroll to and highlight that message on open.
  function flashMsg(id) {
    const node = document.getElementById(`m${id}`);
    if (node) { node.classList.add("hl"); setTimeout(() => node.classList.remove("hl"), 1600); return node; }
    return null;
  }
  async function permalink(id) {
    const url = `${location.origin}${location.pathname}#m${id}`;
    try { await navigator.clipboard.writeText(url); } catch {}
    try { history.replaceState(null, "", `#m${id}`); } catch {}
    flashMsg(id);
  }

  // ---------- STT ----------
  function initRec() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) { err = "no speech recognition in this browser (use Chrome/Android)"; return null; }
    const r = new SR();
    // continuous=FALSE is the fix for the duplication ("I think I think it's I think it's..."). In
    // continuous mode Android Chrome's INTERIM result repeats the already-finalized words, so
    // final("I think") + interim("I think it's") concatenated to "I think I think it's". With
    // continuous=false each utterance is self-contained: e.results holds only the current phrase, we
    // rebuild draft = base(prior committed text) + this phrase, and onend restarts for the next one.
    r.lang = "en-US"; r.continuous = false; r.interimResults = true;
    r.onstart = () => { sttBase = draft ? draft.replace(/\s+$/, "") + " " : ""; };
    r.onresult = (e) => {
      let txt = "";
      for (let i = 0; i < e.results.length; i++) txt += e.results[i][0].transcript;
      const final = e.results.length && e.results[e.results.length - 1].isFinal;
      if (final && voiceCommand(txt)) { scrollTa(); return; }
      if (final && txt.trim()) undoStack = [...undoStack.slice(-9), sttBase.replace(/\s+$/, "")];
      interim = txt;
      draft = (sttBase + txt).replace(/[ \t]+/g, " ").trimStart();
      scrollTa();
    };
    r.onerror = (e) => { if (e.error !== "no-speech" && e.error !== "aborted") err = "mic: " + e.error; };
    r.onend = () => { interim = ""; if (listening) { try { r.start(); } catch {} } };  // next utterance
    return r;
  }
  function toggleMic() {
    if (!rec) rec = initRec();
    if (!rec) return;
    listening = !listening;
    if (listening) { stopSpeaking(); try { rec.start(); } catch {} }
    else { try { rec.stop(); } catch {} }
  }

  onMount(() => {
    document.addEventListener("selectionchange", onSelect);
    // ready=true FIRST and in a finally: a throw in isAdmin()/getToken() (some mobile privacy modes
    // make localStorage access throw) must never leave the page stuck on the "…" loading state.
    try {
      admin = isAdmin();
      // restore the narration (auto-read) preference; default on if never set. Read here in onMount
      // (client-only, post-hydration) rather than at module init to stay off the hydration path.
      try { const v = localStorage.getItem("claude_ui_autoread"); if (v !== null) autoRead = v === "1"; } catch {}
      if (admin) {
        // seed lastId to the newest so we don't replay the whole history / TTS-flood on load
        fetch(`${pgrst}/claude_msg?order=id.desc&limit=25`, { headers: { Authorization: `Bearer ${getToken()}` } })
          .then((r) => r.ok ? r.json() : [])
          .then((rows) => { msgs = rows.reverse(); lastId = rows.length ? Math.max(...rows.map((m) => m.id)) : 0;
                            { const s = [...msgs].reverse().find((m) => m.direction === "out" && m.suggest); if (s) suggestion = s.suggest; }
                            queueMicrotask(() => {
                              // opened via a permalink (#m<id>)? scroll to & flash it; else go to newest.
                              const h = (location.hash || "").match(/^#m(\d+)$/);
                              const node = h && document.getElementById(`m${h[1]}`);
                              if (node) { node.scrollIntoView({ block: "center" }); flashMsg(h[1]); }
                              else el?.scrollTo(0, el.scrollHeight);
                            }); })
          .catch(() => {})
          .finally(() => { loadingMsgs = false; poll = setInterval(fetchNew, 2000); });
      }
    } catch (e) {
      err = "init: " + (e?.message || e);
    } finally {
      ready = true;
    }
  });
  onDestroy(() => { if (poll) clearInterval(poll); stopSpeaking(); try { rec?.stop(); } catch {} });
</script>

<svelte:head><title>Claude</title><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1" /><meta name="robots" content="noindex" /></svelte:head>

{#if !ready}<p class="muted">…</p>
{:else if !admin}<p class="muted">Admins only.</p>
{:else}
<div class="wrap">
  <header>
    <b>🎙 voice</b>
    <!-- WORKING / WAITING. The whole point is knowing whether to expect a reply or to type, so it
         sits in the header where it is always visible, not buried near the composer. -->
    {#if busy}
      <span class="busy {busy}" title={busy === "working"
            ? "Claude is mid-turn (last transcript record was a tool call or a fresh prompt)"
            : "Claude finished its turn -- waiting for you"}>
        {busy === "working" ? "⣾ working" : "⏸ waiting"}
        {#if busySince}<em>{ago(busySince)}</em>{/if}
      </span>
    {/if}
    <div class="tg">
      <button class="emg" on:click={() => ctl("int")} title="interrupt the current turn (SIGINT, like ESC)">⎋ esc</button>
      <button class="emg hard" on:click={() => ctl("int2")} title="double SIGINT (Ctrl-C)">■ stop</button>
      <button class:on={autoRead} on:click={() => { autoRead = !autoRead; if (!autoRead) stopSpeaking(); try { localStorage.setItem("claude_ui_autoread", autoRead ? "1" : "0"); } catch {} }} title="read new replies aloud">🔊 {autoRead ? "auto" : "off"}</button>
      <button on:click={stopSpeaking} title="stop speaking">🔇</button>
    </div>
  </header>

  {#if err}<div class="err">{err}</div>{/if}

  <!-- CHRONOLOGICAL: oldest at top, newest at the BOTTOM just above the composer.
       New messages append at the bottom, so scroll-to-latest means scroll to scrollHeight. -->
  <div class="log" bind:this={el} on:scroll={countUnseen}>
    {#each msgs as m (m.id)}
      <div class="m {m.direction}" id={`m${m.id}`}
           on:touchstart={(e) => pressStart(m, e)} on:touchmove={(e) => pressMove(m, e)}
           on:touchend={pressEnd} on:touchcancel={pressEnd}
           on:mousedown={(e) => pressStart(m, e)} on:mousemove={(e) => pressMove(m, e)}
           on:mouseup={pressEnd} on:mouseleave={pressEnd}>
        {#if m.direction === "out"}
          <div class="bubble a">{@html md(m.body)}</div>
          <span class="acts">
            <button class="ico" on:click={() => permalink(m.id)} title="copy link to this message">🔗</button>
            <button class="ico" on:click={() => speak(m.body)} title="read aloud">🔊</button>
          </span>
        {:else if m.direction === "sys"}
          <div class="chip" title="background task notification">⚙ {m.body}</div>
          <button class="ico" on:click={() => permalink(m.id)} title="copy link to this message">🔗</button>
        {:else if isNotify(m)}
          <button class="ico" on:click={() => permalink(m.id)} title="copy link to this message">🔗</button>
          <div class="bubble n" title="automated alert routed through the user channel">{notifyBody(m.body)}</div>
        {:else}
          <button class="ico" on:click={() => permalink(m.id)} title="copy link to this message">🔗</button>
          <div class="bubble u">{@html mdQuote(m.body)}</div>
        {/if}
      </div>
      {#if tsShown === m.id}
        <div class="tsline {m.direction}">{stamp(m.ts)}</div>
      {/if}
      {#if m.direction === "out" && m.suggest}
        <!-- inline suggested reply, tappable right inside the conversation -->
        <button class="msgsuggest" on:click={() => useSuggestion(m.suggest)} title="tap to use this reply">
          <span class="ms-i">💡</span><span class="ms-t">{m.suggest}</span><span class="ms-go">use ⇥</span>
        </button>
      {/if}
    {/each}
    <!-- LIVE CHURN, IN THE LOG: the header pill says WHETHER work is happening;
         this says HOW LONG, in the place the answer will appear, so the wait has context. When the
         turn ends the relay writes a permanent '⏱ churned ...' sys row and this line disappears --
         the transient and the record are deliberately formatted the same. -->
    {#if busy === "working" && busySince}
      <div class="m sys"><div class="chip live">⏱ churning {churn(busySince)}…</div></div>
    {/if}
    {#if loadingMsgs}
      <div class="loading mid"><span class="spin" aria-hidden="true"></span> Loading conversation…</div>
    {:else if !msgs.length}
      <p class="muted mid">No messages yet. Tap the mic and talk, or type below.</p>
    {/if}
  </div>

  {#if quoteBtn}
    <button class="quotebtn" style="left:{quoteBtn.x}px; top:{quoteBtn.y}px"
            on:mousedown|preventDefault={quoteSelection}
            on:touchstart|preventDefault={quoteSelection}>❝ Quote</button>
  {/if}

  {#if unseen > 0}
    <!-- the ONLY affordance for new arrivals: says how many are below, taps to go there. -->
    <button class="unseen" on:click={toBottom} title="jump to the newest message">↓ {unseen} new</button>
  {/if}

  <!-- Claude's suggested next prompt: shown when the composer is empty. Tap the row (or press Tab /
       the ⇥ button) to drop it into the box for editing — never auto-sends. -->
  {#if suggestion && !draft}
    <button class="suggest" on:click={acceptSuggestion} title="Tab to use this">
      <span class="sg-lbl">💡 suggested</span>
      <span class="sg-txt">{suggestion}</span>
      <span class="sg-tab">⇥ Tab</span>
    </button>
  {/if}

  <!-- INPUT AT BOTTOM -->
  <footer>
    <button class="mic" class:on={listening} on:click={toggleMic} title="tap to talk">{listening ? "● listening" : "🎤"}</button>
    <!-- Ctrl/Cmd+Enter = send; plain Enter makes a newline so dictated/multi-line
         drafts don't fire off mid-composition. Tab (empty box) accepts Claude's suggestion. -->
    <textarea class="ta" rows="2" placeholder={cmdFlash ? `✓ ${cmdFlash}` : (interim || suggestion || "message…")} bind:value={draft} bind:this={taEl}
              on:keydown={(e) => {
                if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); send(); }
                else if (e.key === "Tab" && suggestion && !draft) { e.preventDefault(); acceptSuggestion(); }
              }}></textarea>
    <button class="clr" on:click={clearDraft} disabled={!draft} title="clear">✕</button>
    <button class="snd" on:click={() => send()} disabled={!draft.trim()} title="Ctrl+Enter">send</button>
  </footer>
</div>
{/if}

<style>
  :global(body) { margin: 0; }
  /* 760px was a PHONE-first number: on a desktop it left most of the window as empty margin while
     tables and code blocks inside the bubbles scrolled sideways in a narrow column. Widen with the
     viewport but keep a readable measure -- prose stays near 65-90 characters, and the extra width
     goes to the things that actually need it (tables, pre blocks, the fleet/feature dumps). */
  .wrap { position: relative; display: flex; flex-direction: column; height: 100dvh; width: 100%;
          max-width: min(1200px, 96vw); margin: 0 auto; font-family: system-ui, sans-serif; }
  @media (min-width: 900px) {
    /* on a wide screen an 85%-wide bubble is a 1000px line of prose, which is unreadable. Cap the
       BUBBLE, not the page: wide content inside it still gets the full column via overflow-x. */
    .bubble { max-width: 62rem; }
    .bubble.u, .bubble.n { max-width: 46rem; }
    .msgsuggest { max-width: 62rem; }
  }
  /* WORKING/WAITING pill. Colour carries the state, but so does the glyph and the word -- a colour
     alone fails for a colour-blind reader and in bright sun on a phone, which is where this is read. */
  .chip.live { opacity: .9; animation: pulse 1.6s ease-in-out infinite; }
  @media (prefers-reduced-motion: reduce) { .chip.live { animation: none } }
  .busy { font-size: .72rem; padding: .12rem .5rem; border-radius: 999px; white-space: nowrap;
          display: inline-flex; gap: .3rem; align-items: center; }
  .busy em { font-style: normal; opacity: .65; font-variant-numeric: tabular-nums; }
  .busy.working { background: #1f3a24; color: #7ee08a; animation: pulse 1.6s ease-in-out infinite; }
  .busy.waiting { background: #33302a; color: #d9c48a; }
  @keyframes pulse { 0%,100% { opacity: 1 } 50% { opacity: .55 } }
  /* A pulsing pill is motion the user did not ask for; respect the OS setting. */
  @media (prefers-reduced-motion: reduce) { .busy.working { animation: none } }
  header { display: flex; align-items: center; justify-content: space-between; padding: .5rem .7rem; border-bottom: 1px solid #e6eaed; }
  header b { color: #1c2733; }
  .tg button { border: 1px solid #ddd; background: #fff; border-radius: 999px; padding: .2rem .6rem; font-size: .8rem; color: #666; cursor: pointer; margin-left: .3rem; }
  .tg button.on { border-color: #1e8f4e; color: #1e8f4e; font-weight: 600; }
  .tg button.emg { border-color: #e0a800; color: #a06f00; font-weight: 600; }
  .tg button.emg.hard { border-color: #c0392b; color: #c0392b; }
  .log { flex: 1; overflow-y: auto; padding: .6rem; display: flex; flex-direction: column; gap: .5rem; background: #f7f9fa; }
  .m { display: flex; align-items: flex-start; gap: .3rem; }
  .m.in { justify-content: flex-end; }
  .m.sys { justify-content: center; }
  /* neutral system/task-notification chip: centered, muted, clearly neither the user nor Claude */
  .chip { background: #eceff1; color: #5b6570; border: 1px solid #dfe4e8; border-radius: 999px;
          padding: .25rem .7rem; font-size: .8rem; max-width: 90%; text-align: center; }
  .bubble { border-radius: 14px; padding: .5rem .75rem; max-width: 85%; font-size: .95rem; line-height: 1.45; }
  .bubble.a { background: #fff; border: 1px solid #e4e8ec; color: #1c2733; border-top-left-radius: 4px; }
  .bubble.u { background: #1e8f4e; color: #fff; border-top-right-radius: 4px; white-space: pre-wrap; }
  /* "user system": same side as the user, deliberately NOT the user green. Muted violet so a
     wall of alerts does not shout louder than the conversation around it. */
  .bubble.n { background: #ede7f6; color: #4527a0; border: 1px solid #d1c4e9;
              border-top-right-radius: 4px; white-space: pre-wrap; font-size: .88rem;
              font-variant-numeric: tabular-nums; }
  .bubble.a :global(pre) { background: #f2f4f6; border-radius: 8px; padding: .5rem; overflow-x: auto; font-size: .82rem; }
  .bubble.a :global(code) { background: #f0f2f4; padding: 0 .25rem; border-radius: 4px; font-size: .86em; }
  .bubble.a :global(pre code) { background: none; padding: 0; }
  .bubble.a :global(h3), .bubble.a :global(h4), .bubble.a :global(h5), .bubble.a :global(h6) { margin: .4rem 0 .2rem; font-size: 1rem; color: #1c2733; }
  .bubble.a :global(p) { margin: .3rem 0; } .bubble.a :global(ul), .bubble.a :global(ol) { margin: .3rem 0; padding-inline-start: 1.2rem; }
  .bubble.a :global(a) { color: #2d7dd2; }
  .bubble.a :global(table) { border-collapse: collapse; margin: .4rem 0; font-size: .82rem; display: block; overflow-x: auto; max-width: 100%; }
  .bubble.a :global(th), .bubble.a :global(td) { border: 1px solid #e0e4e8; padding: .2rem .45rem; text-align: left; white-space: nowrap; }
  .bubble.a :global(th) { background: #f2f4f6; font-weight: 600; }
  .bubble.a :global(td) { font-variant-numeric: tabular-nums; }
  /* icon buttons (permalink 🔗 + narration 🔊). grouped in .acts on Claude's messages, standalone
     on the user's / system's. Subtle until hovered so they don't compete with the message text. */
  .acts { display: flex; flex-direction: column; gap: .1rem; flex: 0 0 auto; }
  .ico { border: none; background: none; cursor: pointer; font-size: .82rem; opacity: .4; padding: .15rem .2rem; line-height: 1; }
  .ico:hover { opacity: 1; }
  /* permalink flash: briefly ring a message when it's linked-to or opened via #m<id> */
  .m.hl > .bubble, .m.hl > .chip { box-shadow: 0 0 0 2px #f0b400; transition: box-shadow .2s; }
  .muted { color: #99a2ab; } .mid { text-align: center; margin: auto; }
  /* PHONE: assistant messages get the FULL width. The 85% cap is a chat convention that suits short
     back-and-forth; here the assistant turns are dense technical reports with tables, code blocks and
     long URLs, and surrendering 15% of a phone screen to symmetry makes them harder to read and
     forces avoidable wrapping. User turns stay capped and right-aligned, so the direction of a
     message is still obvious without the width cue. Side padding is trimmed for the same reason. */
  @media (max-width: 640px) {
    .log { padding: .4rem .3rem; gap: .4rem; }
    .bubble { max-width: 100%; }
    .bubble.a { max-width: 100%; padding: .5rem .55rem; }
    .bubble.u, .bubble.n { max-width: 88%; }
    .msgsuggest { max-width: 97%; }
    .bubble.a :global(pre) { padding: .4rem; font-size: .78rem; }
  }
  .err { color: #c0392b; font-size: .8rem; padding: .2rem .7rem; }
  /* inline suggested reply, attached under Claude's message (left-aligned, tappable) */
  /* fixed, not absolute: getBoundingClientRect gives viewport coordinates */
  .quotebtn { position: fixed; transform: translate(-50%, -125%); z-index: 20;
             background: #1c2733; color: #fff; border: none; border-radius: 999px;
             padding: .3rem .8rem; font-size: .8rem; cursor: pointer; white-space: nowrap;
             box-shadow: 0 2px 10px rgba(0,0,0,.3); }
  .quotebtn:hover { background: #2d3b4a; }
  .unseen { position: absolute; left: 50%; transform: translateX(-50%); bottom: 4.6rem; z-index: 5;
           background: #1c2733; color: #fff; border: none; border-radius: 999px;
           padding: .32rem .95rem; font-size: .82rem; cursor: pointer;
           box-shadow: 0 2px 10px rgba(0,0,0,.28); }
  .unseen:hover { background: #2d3b4a; }
  .loading { display: flex; align-items: center; justify-content: center; gap: .5rem;
             color: #8a949c; font-size: .88rem; padding: 1.2rem 0; }
  .spin { width: 14px; height: 14px; border-radius: 50%; border: 2px solid #d7dde2;
          border-top-color: #1e8f4e; animation: sp .8s linear infinite; }
  @keyframes sp { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { .spin { animation-duration: 2.4s; } }
  /* email-style quote: a rule down the left, muted, and it must read on BOTH the white assistant
     bubble and the green user bubble -- hence currentColor at low opacity rather than a fixed grey */
  .bubble :global(blockquote) { margin: .35rem 0; padding: .1rem 0 .1rem .6rem;
                                border-left: 3px solid currentColor; opacity: .72;
                                white-space: pre-wrap; }
  .bubble.a :global(blockquote) { border-left-color: #c7d0d8; color: #55606b; opacity: 1; }
  .tsline { font-size: .7rem; color: #8a949c; padding: 0 .3rem; margin: -.15rem 0 .2rem;
            font-variant-numeric: tabular-nums; }
  .tsline.out, .tsline.sys { align-self: flex-start; }
  .tsline.in { align-self: flex-end; }
  .m { -webkit-touch-callout: none; }
  .msgsuggest { display: inline-flex; align-items: flex-start; gap: .4rem; max-width: 85%; align-self: flex-start; text-align: start;
                margin: -.2rem 0 .1rem; border: 1px solid #bcdff0; background: #eef7fc; color: #1b5e86;
                border-radius: 14px; padding: .35rem .6rem .35rem .5rem; cursor: pointer; text-align: start;
                font-size: .86rem; line-height: 1.3; }
  .msgsuggest:hover { background: #e0f0fa; border-color: #8fc7e6; }
  .ms-i { flex: 0 0 auto; }
  .ms-t { flex: 1 1 auto; }
  .ms-go { flex: 0 0 auto; font-size: .68rem; color: #4a8bb0; border: 1px solid #bcdff0; border-radius: 6px; padding: .02rem .3rem; background: #fff; }
  /* Claude's suggested-prompt bar, sits just above the composer */
  .suggest { display: flex; align-items: center; gap: .5rem; width: 100%; text-align: start;
             border: 1px dashed #cdd6df; background: #f4f8fb; border-radius: 12px; cursor: pointer;
             padding: .45rem .7rem; margin: 0 .5rem; box-sizing: border-box; width: calc(100% - 1rem); }
  .suggest:hover { background: #eaf2f8; border-color: #9fbdd6; }
  .sg-lbl { flex: 0 0 auto; font-size: .7rem; color: #2d7dd2; font-weight: 600; text-transform: uppercase; letter-spacing: .03em; }
  /* SHOW THE SUGGESTION, do not ellipse it away. nowrap+ellipsis truncated it to a few words on a
     phone, so the one thing the row exists to communicate -- what Claude is proposing you say -- was
     the part cut off. Wraps to at most two lines; longer than that and the suggestion is badly
     written, not badly displayed. */
  .sg-txt { flex: 1 1 auto; min-width: 0; color: #33404d; font-size: .9rem; white-space: normal;
            overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
            line-height: 1.3; }
  .sg-tab { flex: 0 0 auto; font-size: .72rem; color: #66707c; border: 1px solid #d5dde4; border-radius: 6px; padding: .05rem .35rem; background: #fff; }
  footer { display: flex; gap: .4rem; padding: .5rem; border-top: 1px solid #e6eaed; align-items: center; }
  .mic { flex: 0 0 auto; min-width: 48px; height: 44px; border: 1px solid #ccc; border-radius: 22px; background: #fff; font-size: 1.1rem; cursor: pointer; padding: 0 .7rem; }
  .mic.on { background: #c0392b; color: #fff; border-color: #c0392b; animation: pulse 1.2s infinite; }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: .6; } }
  footer .ta { flex: 1; min-width: 0; border: 1px solid #ccc; border-radius: 16px; padding: .5rem .9rem; font-size: 1rem; font-family: inherit; resize: none; line-height: 1.35; max-height: 40dvh; overflow-y: auto; }
  .clr { flex: 0 0 auto; width: 44px; height: 44px; border: 1px solid #ccc; border-radius: 22px; background: #fff; color: #888; font-size: 1rem; cursor: pointer; }
  .clr:disabled { opacity: .3; }
  .snd { flex: 0 0 auto; height: 44px; border: none; border-radius: 22px; background: #1e8f4e; color: #fff; padding: 0 1.1rem; font-size: .95rem; cursor: pointer; }
  .snd:disabled { opacity: .4; }
  :global(img.cui-img) { max-width: 100%; max-height: 70vh; border-radius: 6px; cursor: zoom-in; display: block; margin: 6px 0; }
</style>
