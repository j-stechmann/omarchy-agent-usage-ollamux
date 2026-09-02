# omarchy-agent-usage-ollamux

An [omarchy](https://omarchy.org) quattro agents-panel collector for
[ollamux](https://github.com/j-stechmann/ollamux), the key-rotating reverse
proxy for Ollama Cloud.

Omarchy's `omarchy.agents` bar panel shows usage, limits, and per-model token
breakdowns for every AI coding subscription on the machine. It discovers
agents through collector scripts named `omarchy-agent-usage-<id>` in
`$OMARCHY_PATH/bin`, each of which prints one display-ready JSON record. This
repo ships the `ollamux` collector, so opencode traffic that runs through your
own ollamux provider gets its own tab instead of being invisible to the panel.

Omarchy's built-in `claude` and `codex` collectors only pick up opencode
sessions that ran on an Anthropic or OpenAI provider — a custom provider like
`ollamux` never shows up. This collector fills that gap.

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
sudo install -m755 omarchy-agent-usage-ollamux /usr/share/omarchy/bin/
```

That's it. No settings change needed — the panel picks up any collector that
appears in `$OMARCHY_PATH/bin`, and the bar icon arrives on the next refresh.
To force one immediately:

```bash
omarchy-agent-usage-update ollamux
omarchy-shell omarchy.agents refresh
```

The file is not owned by pacman, so omarchy updates leave it in place.

To uninstall:

```bash
sudo rm /usr/share/omarchy/bin/omarchy-agent-usage-ollamux
rm -f ~/.local/state/omarchy/agents/usage/ollamux.json
```

## Requirements

- omarchy quattro (4.x) with the `omarchy.agents` shell plugin (ships in the
  default bar layout)
- opencode, with sessions that ran on a provider id of `ollamux`
- a reachable ollamux proxy for the limit meters (local stats work without it)

The provider id must match: if your `opencode.json` keys the provider
differently (e.g. `ollamux2`), change `PROVIDER_ID` in the script.

## Configuration

Everything has a sensible default; all of this is optional.

| Env var | Default | What it does |
|---|---|---|
| `OLLAMUX_BASE_URL` | `http://127.0.0.1:11435` | Base URL of the ollamux proxy. The collector appends `/api/usage`. |
| `XDG_DATA_HOME` | `~/.local/share` | Where to find `opencode/opencode.db`. |
| `XDG_CACHE_HOME` | `~/.cache` | Where scan/limit caches live (`omarchy/agent-usage/`). |

## CLI

```
omarchy-agent-usage-ollamux [--force] [--limits-only]
```

- `--force` — rescan the database and re-probe limits, ignoring caches
- `--limits-only` — reuse a database scan up to 15 minutes old; only the
  limits probe must be fresh

Both flags exist so the collector accepts the same invocation as every other
omarchy collector; `omarchy-agent-usage-update` passes them through.

Output is a single JSON record on stdout — the same contract as the built-in
collectors. See `omarchy-agent-usage-claude` for the authoritative shape.

## How it works

- **Scans are cached and deduplicated.** The update command runs one collector
  per agent in the background while the panel refreshes on its own timer, so a
  scan younger than 20 seconds is reused (15 minutes under `--limits-only`),
  guarded by a lock file to collapse concurrent runs.
- **The database is opened read-only** (`?mode=ro` + `PRAGMA query_only`) with
  a 2-second busy timeout — opencode may be writing mid-scan. Rows with a
  missing/malformed payload are skipped rather than aborting the scan.
- **Thinking tokens count as output.** opencode stores reasoning tokens
  separately from output; the panel's "tokens by model" treats both as
  generated, so they are summed.
- **Limits are probed at most every 15 seconds.** Panel opens and shuts do not
  turn into a request per flick; a recent probe result is reused and kept as
  the answer of record when the proxy later fails.

## record shape

For reference, the record this prints (fields the panel actually reads):

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