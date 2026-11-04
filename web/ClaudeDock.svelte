<script>
  // CLAUDE DOCK: the same chat as ClaudePage, embeddable on every page of a host site. Put it once in
  // the host's root layout; it stays mounted across client-side navigation, so the conversation and
  // its scroll position survive moving between pages.
  //   closed -> a round launcher button, bottom right
  //   popup  -> a floating chat window over the page, bottom right (full screen on a phone)
  //   side   -> pinned as a full-height panel on the right (wide screens), resizable from its left
  //             edge; the page makes room for it (body margin), so nothing is hidden behind it
  // State and width are per browser (localStorage). Closing unmounts ClaudePage, which stops its polling.
  import { onMount, onDestroy } from "svelte";
  import ClaudePage from "./ClaudePage.svelte";
  // HOST CONTRACT: ClaudePage's three props, plus
  export let pgrst;
  export let getToken;
  export let isAdmin;
  export let hidden = false;          // host hides the dock, e.g. on its full-page claude route
  export let storageKey = "claude_ui_dock";
  // keyboard toggle (closed <-> the last open mode), e.g. "Ctrl+Backquote", "Alt+Shift+KeyK"; false = none.
  // Modifiers + a KeyboardEvent.code, so it is the physical key in any layout (Hebrew too). The default is
  // free in browsers and most sites (Ctrl+` toggles a side panel in VS Code too) and types no character,
  // so it also works while focus is in a text field, including the chat's own.
  export let hotkey = "Ctrl+Backquote";

  const SIDE_MIN = 1000;              // narrower than this, "side" falls back to the popup
  let mode = "closed";                // closed | popup | side
  let w = 440;
  let last = "popup";                 // the open mode the hotkey and launcher return to
  try { ({ mode = "closed", w = 440, last = "popup" } = JSON.parse(localStorage.getItem(storageKey) ?? "{}")); } catch {}
  $: if (mode !== "closed") last = mode;
  $: try { localStorage.setItem(storageKey, JSON.stringify({ mode, w, last })); } catch {}

  $: keys = parseHotkey(hotkey);
  $: hint = keys ? String(hotkey).replace(/Backquote/, "`").replace(/Key([A-Z])|Digit(\d)/g, "$1$2") : "";
  function parseHotkey(h) {
    if (!h) return null;
    const parts = String(h).split("+").map((x) => x.trim());
    const code = parts.pop();
    const mods = new Set(parts.map((x) => x.toLowerCase()));
    return { code, ctrl: mods.has("ctrl"), alt: mods.has("alt"), shift: mods.has("shift"), meta: mods.has("meta") };
  }
  function onKey(e) {
    if (off || !keys || e.repeat || e.code !== keys.code || e.ctrlKey !== keys.ctrl || e.altKey !== keys.alt
        || e.shiftKey !== keys.shift || e.metaKey !== keys.meta) return;
    e.preventDefault();
    mode = mode === "closed" ? last : "closed";
  }

  let vw = typeof window === "undefined" ? 0 : window.innerWidth;
  const onResize = () => (vw = window.innerWidth);
  // never shown to non-admins, whatever the host passes (the API refuses them anyway). Re-checked every
  // second: isAdmin() reads the host's session, which can change (sign in / out) without any prop changing.
  let admin = false;
  const checkAdmin = () => { try { admin = !!isAdmin(); } catch { admin = false; } };
  let adminTimer;
  // browser-only setup in onMount, so hosts that server-render can mount the dock without a browser gate
  onMount(() => {
    checkAdmin();
    adminTimer = setInterval(checkAdmin, 1000);
    addEventListener("resize", onResize);
    addEventListener("keydown", onKey);
  });
  $: off = hidden || !admin;
  $: shown = off ? "closed" : mode === "side" && vw < SIDE_MIN ? "popup" : mode;

  // SIDE makes room on the page itself: a margin on <html> works for any host layout, sticky headers included
  $: if (typeof document !== "undefined") {
    const root = document.documentElement;
    root.style.setProperty("--claude-dock-w", `${w}px`);
    root.classList.toggle("claude-docked", shown === "side");
  }
  onDestroy(() => {
    if (typeof window === "undefined") return;
    removeEventListener("resize", onResize);
    removeEventListener("keydown", onKey);
    clearInterval(adminTimer);
    document.documentElement.classList.remove("claude-docked");
  });

  function grab(e) {
    const move = (m) => (w = Math.round(Math.min(Math.max(innerWidth - m.clientX, 320), innerWidth * 0.7)));
    const up = () => { removeEventListener("pointermove", move); removeEventListener("pointerup", up); document.body.style.userSelect = ""; };
    document.body.style.userSelect = "none";   // no text selection while dragging
    addEventListener("pointermove", move);
    addEventListener("pointerup", up);
    e.preventDefault();
  }
</script>

{#if shown === "closed"}
  {#if !off}
    <button class="cui-launch" on:click={() => (mode = last)}
            title={hint ? `Chat with Claude (${hint})` : "Chat with Claude"} aria-label="Chat with Claude" aria-keyshortcuts={hint || undefined}>💬</button>
  {/if}
{:else}
  <aside class="cui-dock {shown}" style:--w="{w}px" aria-label="Claude chat">
    {#if shown === "side"}
      <div class="grip" role="separator" aria-orientation="vertical" aria-label="Resize the Claude panel" on:pointerdown={grab}></div>
    {/if}
    <div class="ctl">
      {#if vw >= SIDE_MIN}
        <button on:click={() => (mode = shown === "side" ? "popup" : "side")}
                title={shown === "side" ? "Float as a popup" : "Pin to the side of the page"}>{shown === "side" ? "⧉" : "◨"}</button>
      {/if}
      <button on:click={() => (mode = "closed")} title={hint ? `Close (${hint})` : "Close"} aria-label="Close">×</button>
    </div>
    <ClaudePage {pgrst} {getToken} {isAdmin} />
  </aside>
{/if}

<style>
  :global(html.claude-docked) { margin-right: var(--claude-dock-w); }
  .cui-launch { position: fixed; right: 1.1rem; bottom: 1.1rem; z-index: 1000; width: 3.2rem; height: 3.2rem;
                border-radius: 50%; border: 0; background: #1e8f4e; color: #fff; font-size: 1.4rem; cursor: pointer;
                box-shadow: 0 4px 14px rgba(0,0,0,.25); padding: 0; }
  .cui-launch:hover { filter: brightness(1.1); }
  .cui-dock { position: fixed; z-index: 1000; background: #fff; display: flex; flex-direction: column; }
  .cui-dock.popup { right: 1.1rem; bottom: 1.1rem; width: min(440px, calc(100vw - 2.2rem)); height: min(680px, calc(100dvh - 2.2rem));
                    border-radius: 12px; overflow: hidden; box-shadow: 0 8px 30px rgba(0,0,0,.28); border: 1px solid #dfe4e8; }
  .cui-dock.side { top: 0; right: 0; bottom: 0; width: var(--w); border-left: 1px solid #dfe4e8; }
  @media (max-width: 600px) {
    .cui-dock.popup { inset: 0; width: auto; height: auto; border-radius: 0; border: 0; }
  }
  /* ClaudePage sizes itself to the viewport (100dvh, 96vw); in the dock it fills the panel instead */
  .cui-dock :global(.wrap) { height: 100%; max-width: none; flex: 1; min-height: 0; }
  /* dock controls float over the top-left of ClaudePage's header (its right side holds its own toggles) */
  .ctl { position: absolute; top: .4rem; left: .4rem; z-index: 2; display: flex; gap: .2rem; }
  .ctl button { border: 1px solid #ddd; background: #fff; color: #555; border-radius: 6px; width: 1.7rem; height: 1.7rem;
                padding: 0; font-size: .95rem; line-height: 1; cursor: pointer; }
  .ctl button:hover { border-color: #1e8f4e; color: #1e8f4e; }
  .cui-dock :global(.wrap > header) { padding-left: 4.4rem; }
  .grip { position: absolute; left: -3px; top: 0; bottom: 0; width: 6px; cursor: col-resize; z-index: 3; }
  .grip:hover { background: #cfe9da; }
</style>
