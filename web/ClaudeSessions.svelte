<script>
  // CLAUDE SESSIONS: who used the host's admin pages when (optional presence tracking, see ClaudeDock's
  // presence prop). Per user: sessions, total time, page loads, messages; then every session with its
  // start/end, duration, page loads, views, top urls and messages sent to claude-ui. Same props as ClaudePage.
  import { onMount, onDestroy } from "svelte";
  export let pgrst;
  export let getToken;
  export let isAdmin;
  let rows = [], err = "", who = "", loaded = false, timer;
  const auth = () => ({ Authorization: `Bearer ${getToken()}` });
  async function load() {
    try {
      const r = await fetch(`${pgrst}/claude_sessions?order=started_at.desc&limit=500`, { headers: auth() });
      if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
      rows = await r.json(); err = ""; loaded = true;
    } catch (e) { err = String(e.message || e); }
  }
  onMount(() => { load(); timer = setInterval(load, 15000); });
  onDestroy(() => clearInterval(timer));
  const secs = (iv) => {                      // postgres interval text "01:02:03.45" or "1 day 02:00:00"
    if (!iv) return 0;
    const m = String(iv).match(/(?:(\d+) days? )?(\d+):(\d+):(\d+)/);
    return m ? (+(m[1] || 0)) * 86400 + (+m[2]) * 3600 + (+m[3]) * 60 + (+m[4]) : 0;
  };
  const dur = (s) => s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  const when = (t) => new Date(t).toLocaleString(undefined, { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
  const top = (urls, n = 4) => Object.entries(urls || {}).sort((a, b) => b[1] - a[1]).slice(0, n);
  $: users = [...new Set(rows.map((r) => r.who))].sort();
  $: shown = who ? rows.filter((r) => r.who === who) : rows;
  $: summary = users.map((u) => {
    const rs = rows.filter((r) => r.who === u);
    const urls = {};
    for (const r of rs) for (const [k, v] of Object.entries(r.urls || {})) urls[k] = (urls[k] || 0) + v;
    return { who: u, online: rs.some((r) => r.online), sessions: rs.length, time: rs.reduce((a, r) => a + secs(r.duration), 0),
             loads: rs.reduce((a, r) => a + r.page_loads, 0), views: rs.reduce((a, r) => a + r.views, 0),
             messages: rs.reduce((a, r) => a + r.messages, 0), last: rs[0]?.ended_at, urls };
  });
</script>

{#if !isAdmin()}<p class="muted">Admins only.</p>
{:else}
<div class="cs">
  {#if err}<p class="err">{err}</p>{/if}
  <h3>Users</h3>
  <table>
    <thead><tr><th>User</th><th>Last seen</th><th class="n">Sessions</th><th class="n">Time</th><th class="n">Page loads</th><th class="n">Views</th><th class="n">Messages</th><th>Top pages</th></tr></thead>
    <tbody>
      {#each summary as u}
        <tr class:sel={who === u.who} on:click={() => (who = who === u.who ? "" : u.who)}>
          <td><span class="dot" class:on={u.online} title={u.online ? "online now" : "offline"}></span><b>{u.who}</b></td>
          <td>{u.last ? when(u.last) : ""}</td><td class="n">{u.sessions}</td><td class="n">{dur(u.time)}</td>
          <td class="n">{u.loads}</td><td class="n">{u.views}</td><td class="n">{u.messages}</td>
          <td class="urls">{#each top(u.urls, 5) as [k, v]}<span>{k} <i>{v}</i></span>{/each}</td>
        </tr>
      {/each}
      {#if loaded && !summary.length}<tr><td colspan="8" class="muted">No sessions yet.</td></tr>{/if}
    </tbody>
  </table>
  <h3>Sessions {#if who}— {who} <button on:click={() => (who = "")}>all</button>{/if}</h3>
  <table>
    <thead><tr><th>User</th><th>Start</th><th>End</th><th class="n">Duration</th><th class="n">Page loads</th><th class="n">Views</th><th class="n">Messages</th><th>Pages</th></tr></thead>
    <tbody>
      {#each shown as r (r.id)}
        <tr>
          <td><span class="dot" class:on={r.online}></span>{r.who}</td>
          <td>{when(r.started_at)}</td><td>{r.online ? "now" : when(r.ended_at)}</td>
          <td class="n">{dur(secs(r.duration))}</td><td class="n">{r.page_loads}</td><td class="n">{r.views}</td><td class="n">{r.messages}</td>
          <td class="urls" title={r.user_agent}>{#each top(r.urls, 6) as [k, v]}<span>{k} <i>{v}</i></span>{/each}</td>
        </tr>
      {/each}
    </tbody>
  </table>
</div>
{/if}

<style>
  .cs { font-family: system-ui, sans-serif; font-size: .9rem; }
  h3 { margin: 1rem 0 .4rem; font-size: 1rem; }
  table { border-collapse: collapse; width: 100%; background: #fff; }
  th, td { padding: .4rem .55rem; border-bottom: 1px solid #edf1f5; text-align: left; vertical-align: top; }
  th { background: #f7f9fb; color: #66707c; font-weight: 600; font-size: .8rem; white-space: nowrap; }
  .n { text-align: right; white-space: nowrap; }
  tbody tr { cursor: default; } tr.sel td { background: #eef6fc; }
  .dot { display: inline-block; width: .55rem; height: .55rem; border-radius: 50%; background: #c8cfd6; margin-right: .4rem; }
  .dot.on { background: #1e8f4e; }
  .urls span { display: inline-block; margin: 0 .4rem .15rem 0; padding: 0 .35rem; background: #eef2f6; border-radius: 5px; font-size: .78rem; }
  .urls i { color: #66707c; font-style: normal; }
  .muted { color: #99a2ab; } .err { color: #c0392b; }
  button { font-size: .75rem; border: 1px solid #ccd; background: #fff; border-radius: 6px; padding: 0 .4rem; }
</style>
