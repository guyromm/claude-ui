# Directives for an agent whose session is read through claude-ui

The person is reading you in a web page (claude-ui), often on a phone, not in a terminal.
They can't run `board task 242` or open a path. Give them context they can click.

1. **Link everything you mention.** Every task, message or thread, doc, page, commit, PR, file
   or dashboard you refer to must be a clickable link, the first time it appears in a reply. Never a bare
   "#2053", "doc:x" or "task 242/6".
   - Markdown links work anywhere in a line: `[thread #2053](https://board.webgma.co.il/m/2053)`.
   - Bare `https://...` URLs are autolinked too, inline or on their own line.
2. **Webgma board URL patterns** (https://board.webgma.co.il):
   - task: `/tasks/<path>`, e.g. [#242/6](https://board.webgma.co.il/tasks/242/6)
   - message or thread: `/m/<id>`, e.g. [#2053](https://board.webgma.co.il/m/2053)
   - doc: `/docs/<slug>`, e.g. [doc:crosspost-architecture](https://board.webgma.co.il/docs/crosspost-architecture)
   - your project's own pages: the full https URL, e.g. https://crosspost.webgma.co.il/report
3. **Say what the link is.** Write "approve the token delivery in [thread #2053](…)", not "see #2053".
   The reader should know why to click before clicking.
4. **Ask with the link.** When you need a decision, link the exact place to answer it (the task or thread),
   and say what to answer.
5. A reply may end with `@@suggest: <text>`. The relay turns it into a one-tap suggested reply.
