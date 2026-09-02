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

The record combines two sources:

- **Token stats** — read straight out of opencode's database
  (`~/.local/share/opencode/opencode.db`), counting every assistant message
  whose `providerID` is `ollamux`. Input, output, reasoning, and cache tokens
  are aggregated per model, per day, and all-time: today's prompts/sessions,
  the last 7 days, and all-time totals with active days.
- **Limit meters** — asked from the proxy itself (`/api/usage`), which
  reports Ollama Cloud session and weekly utilization. These render as the
  panel's usual percentage meters. The endpoint provides no reset times, so
  no pace line is drawn.

If the proxy is down, the collector keeps showing last-known limits and local
token stats, and the panel surfaces an "Ollamux unreachable" note instead.

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

Manage the plugin with the usual commands:

```bash
omarchy plugin update ollamux.agents   # update to the latest commit
omarchy plugin disable ollamux.agents  # stop publishing, tab disappears
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
- a reachable ollamux proxy for the limit meters (local stats work without it)

The provider id must match: if your `opencode.json` keys the provider
differently (e.g. `ollamux2`), set `OLLAMUX_PROVIDER_ID` (see Configuration).

## Configuration

Everything has a sensible default; all of this is optional. The plugin runs
inside omarchy-shell, so set these in the session environment (e.g.
`~/.config/uwsm/env` or your `~/.config/hypr/` env setup), then
`omarchy restart shell`:

| Env var | Default | What it does |
|---|---|---|
| `OLLAMUX_BASE_URL` | `http://127.0.0.1:11435` | Base URL of the ollamux proxy. The collector appends `/api/usage`. |
| `OLLAMUX_PROVIDER_ID` | `ollamux` | The opencode provider id to count. |
| `XDG_DATA_HOME` | `~/.local/share` | Where to find `opencode/opencode.db`. |
| `XDG_CACHE_HOME` | `~/.cache` | Where scan/limit caches live (`omarchy/agent-usage/`). |

## How it works

- **The plugin is a writer, not a panel.** The built-in `omarchy.agents`
  widget stays the single display. A `service`-kind plugin (like omarchy's
  battery service) is mounted by the shell on `omarchy plugin enable`, runs
  the collector on a timer, and publishes the record atomically into the
  usage directory the panel already watches.
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
  pick one so the record does not get written twice.
- **Scans are cached and deduplicated.** A scan younger than 20 seconds is
  reused to collapse concurrent runs; limits are probed at most every 15
  seconds, so panel open/shut flicks do not turn into a request per flick.
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
  "tierLabel": "Ollama Cloud",
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

## License

GPL-2.0-only — see [LICENSE](LICENSE).