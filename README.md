# omarchy-agent-usage-ollamux

An [omarchy](https://omarchy.org) shell plugin that feeds an **Ollamux** tab
to the built-in `omarchy.agents` bar panel, for [ollamux](https://github.com/j-stechmann/ollamux),
the key-rotating reverse proxy for Ollama Cloud.

Omarchy's `omarchy.agents` panel shows usage, limits, and per-model token
breakdowns for every AI coding subscription on the machine. It discovers
agents through collector scripts named `omarchy-agent-usage-<id>` in
`$OMARCHY_PATH/bin`, each of which prints one display-ready JSON record. The
built-in `claude` and `codex` collectors only pick up opencode sessions that
ran on an Anthropic or OpenAI provider — a custom provider like `ollamux`
never shows up. This plugin fills that gap, so opencode traffic that runs
through your own ollamux provider gets its own tab.

Because it ships as a shell plugin, the whole install is one omarchy command:
no sudo, no files in `/usr/share/omarchy/`, nothing for `omarchy update` to
overwrite, and `omarchy plugin remove` undoes it.

## What it shows

The record combines three sources:

- **Token stats** — read straight out of opencode's database
  (`~/.local/share/opencode/opencode.db`), counting every assistant message
  whose `providerID` is `ollamux`. Input, output, reasoning, and cache tokens
  are aggregated per model, per day, and all-time: today's prompts/sessions,
  the last 7 days, and all-time totals with active days.
- **Limit meters** — asked from the proxy itself (`/api/usage`), which
  reports Ollama Cloud session and weekly utilization. These render as the
  panel's usual percentage meters. The endpoint provides no reset times, so
  no pace line is drawn.
- **Live concurrency** — read from the proxy's per-key slot table (`/_keys`),
  a pure in-memory read with no upstream traffic. It shows up in two places:
  the panel's plan line ("Ollama Cloud · 2/6 busy", with "· 1 queued" appended
  while requests wait for a slot) and the optional bar widget.

If the proxy is down, the collector keeps showing last-known limits and local
token stats, and the panel surfaces an "Ollamux unreachable" note instead.
The concurrency text never lies about age: it is only shown when read fresh —
if the slot table cannot be read, the plan line falls back to plain
"Ollama Cloud" (and the bar widget hides).

### Concurrency, precisely

- `2/6` counts requests in flight over usable slots. Slots belong to keys;
  only keys whose state is `up` contribute capacity — a `cooldown` or `dead`
  key's slots cannot serve anything.
- Queued requests (`+N`) are those the proxy is holding back until a slot
  frees up.
- This is instantaneous state, by design: nothing here alarms, and nothing
  hides when usage is high — a full proxy reads `6/6`, not red.
- The agents-tab text is as fresh as the publish cadence (15 s by default);
  the bar widget polls every 5 s.

## Install

```bash
omarchy plugin add https://github.com/j-stechmann/omarchy-agent-usage-ollamux.git --enable
```

That's it. The plugin runs as a `service` inside omarchy-shell (the same
mechanism as the battery warning service): it runs the bundled collector on a
timer and publishes the record into
`~/.local/state/omarchy/agents/usage/`, the directory the `omarchy.agents`
panel watches. The panel's own README documents that it picks up any record
landing there, so the bar icon and the Ollamux tab arrive on the next panel
refresh — to force one immediately:

```bash
omarchy-shell omarchy.agents refresh
```

The plugin also carries a bar widget with the live `2/6` concurrency readout.
On a **fresh install** it is placed automatically at the right end of the
bar. On an **existing install** (this plugin already enabled when you update
to a version that added the widget), omarchy will not insert the bar entry
for you — re-enable once to place it:

```bash
omarchy plugin disable ollamux.agents && omarchy plugin enable ollamux.agents
```

(Or add `{"id": "ollamux.agents"}` to `bar.layout.right` in
`~/.config/omarchy/shell.json` yourself. `omarchy bar move` and friends
cannot create a layout entry, so the re-enable is the supported path.)

Manage the plugin with the usual commands:

```bash
omarchy plugin update ollamux.agents   # update to the latest commit
omarchy plugin disable ollamux.agents  # stop publishing, tab and widget disappear
omarchy plugin remove ollamux.agents   # uninstall
```

To uninstall completely, also drop the record:

```bash
rm -f ~/.local/state/omarchy/agents/usage/ollamux.json
```

## Requirements

- omarchy quattro (4.x) with the built-in `omarchy.agents` shell plugin
  (ships in the default bar layout)
- opencode, with sessions that ran on a provider id of `ollamux`
- a reachable ollamux proxy for the limit meters, concurrency text, and
  the bar widget (local stats work without it)

The provider id must match: if your `opencode.json` keys the provider
differently (e.g. `ollamux2`), set `OLLAMUX_PROVIDER_ID` (see Configuration).

## Configuration

Everything has a sensible default; all of this is optional. The plugin runs
inside omarchy-shell, so set these in the session environment (e.g.
`~/.config/uwsm/env` or your `~/.config/hypr/` env setup), then
`omarchy restart shell`:

| Env var | Default | What it does |
|---|---|---|
| `OLLAMUX_BASE_URL` | `http://127.0.0.1:11435` | Base URL of the ollamux proxy. The collector appends `/api/usage` and `/_keys`; the bar widget appends `/_keys`. |
| `OLLAMUX_PROVIDER_ID` | `ollamux` | The opencode provider id to count. |
| `OLLAMUX_PUBLISH_INTERVAL` | `15` | Seconds between record publishes from the service (min 5). This is the freshness of the panel's concurrency text. |
| `OLLAMUX_LIMITS_PROBE_MIN_INTERVAL` | `15` | Minimum seconds between upstream `/api/usage` probes for standalone collector runs. |
| `OLLAMUX_PROBE_INTERVAL` | `600` | What the service tells its collector child to use as that minimum — set high so publishing every 15 s does not multiply upstream probes. |
| `XDG_DATA_HOME` | `~/.local/share` | Where to find `opencode/opencode.db`. |
| `XDG_CACHE_HOME` | `~/.cache` | Where scan/limit caches live (`omarchy/agent-usage/`). |

The bar widget has two settings of its own (per-widget, via
`omarchy bar set` or the shell's settings UI): `pollIntervalSec` (default 5,
minimum 2) and `baseUrl` (blank = `OLLAMUX_BASE_URL`/default as above):

```bash
omarchy bar set ollamux.agents pollIntervalSec 5 --json
omarchy bar move ollamux.agents right
```

## How it works

- **The plugin is a writer, not a panel.** The built-in `omarchy.agents`
  widget stays the single display. A `service`-kind plugin (like omarchy's
  battery service) is mounted by the shell on `omarchy plugin enable`, runs
  the collector on a timer, and publishes the record atomically into the
  usage directory the panel already watches.
- **Concurrency is read from the slot table, not guessed.** The proxy
  exposes per-key request state at `/_keys` — a pure in-memory read on the
  proxy side with no upstream traffic, cheap enough to ask on every publish
  and every widget poll. Requests in flight are counted against the slots of
  `up` keys only; `waiters` are the queued tail. The panel's plan line is the
  one free-text slot the record contract offers, so live load rides there;
  nothing touches the panel's rate-limit alarm machinery.
- **The bar widget is display-only.** It polls `/_keys` every few seconds
  (curl with a 3 s timeout, skipped while the previous read is still
  running), shows `active/capacity` (+ queued), and collapses to nothing
  when the proxy is unreachable. No alarms, no popup, no IPC.
- **The collector also works standalone.** `collector/omarchy-agent-usage-ollamux`
  prints one display-ready JSON record on stdout — the same contract as the
  built-in collectors (see `omarchy-agent-usage-claude` for the authoritative
  shape). If you prefer, you can instead copy it into `$OMARCHY_PATH/bin/`
  yourself:

  ```bash
  sudo install -m755 collector/omarchy-agent-usage-ollamux /usr/share/omarchy/bin/
  ```

  Then `omarchy-agent-usage-update` runs it like any built-in collector on
  the panel's own refresh timer. The file is not pacman-owned, so omarchy
  updates leave it in place. The two installation paths are alternatives —
  pick one so the record does not get written twice. (The bin-copy path
  publishes at the panel's refresh cadence, not the service's, so the
  concurrency text updates only on panel refreshes.)
- **Scans are cached and deduplicated.** A scan younger than 20 seconds is
  reused to collapse concurrent runs; upstream limits probes are throttled
  to one per `OLLAMUX_LIMITS_PROBE_MIN_INTERVAL` seconds (15 standalone,
  600 under the service), so panel open/shut flicks and fast publish timers
  do not turn into a request each.
- **The database is opened read-only** (`?mode=ro` + `PRAGMA query_only`)
  with a 2-second busy timeout — opencode may be writing mid-scan. Rows with
  a missing/malformed payload are skipped rather than aborting the scan.
- **Thinking tokens count as output.** opencode stores reasoning tokens
  separately from output; the panel's "tokens by model" treats both as
  generated, so they are summed.

## Record shape

For reference, the record published (fields the panel actually reads):

```jsonc
{
  "schemaVersion": 1,
  "id": "ollamux",
  "name": "Ollamux",
  "tierLabel": "Ollama Cloud · 2/6 busy · 1 queued",
  "ready": true,
  "hasLocalStats": true,
  "hasPromptStats": true,
  "limits": [
    { "label": "Session", "percent": 0.055, "resetsAt": "" },
    { "label": "Weekly", "percent": 0.248, "resetsAt": "" }
  ],
  "usageStatusText": "",
  "authHelpText": "",
  "todayPrompts": 388,
  "todaySessions": 16,
  "todayTotalTokens": 11061724,
  "todayTokensByModel": { "glm-5.3-flash": 11061724 },
  "recentDays": [{ "date": "2026-09-02", "messageCount": 11061724 }],
  "modelUsage": {
    "glm-5.3-flash": {
      "inputTokens": 163099821,
      "outputTokens": 2704917,
      "cacheReadInputTokens": 0,
      "cacheCreationInputTokens": 0
    }
  },
  "totalPrompts": 2811,
  "totalSessions": 82,
  "activeDays": 3,
  "activeDates": ["2026-08-31", "2026-09-01", "2026-09-02"]
}
```

`recentDays[].messageCount` is actually a token total — a legacy field name
kept for compatibility with the other collectors and the sync aggregator.

`tierLabel` normally reads `"Ollama Cloud"`; the concurrency suffix appears
only when the slot table was read fresh at collect time and at least one key
is up. The panel shows `usageStatusText` instead of the tier line whenever
the limits probe failed, so a downed proxy never leaves stale load text
behind.

## License

GPL-2.0-only — see [LICENSE](LICENSE).