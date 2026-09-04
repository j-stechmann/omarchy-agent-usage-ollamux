import QtQuick
import Quickshell
import Quickshell.Io

/*
 * Copyright (C) 2026 j-stechmann
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; version 2 of the License. This program is
 * distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
 * PARTICULAR PURPOSE. See the GNU General Public License for more details.
 */

// The data side of the Ollamux agent tab. The built-in omarchy.agents panel
// is strictly a display: it watches ~/.local/state/omarchy/agents/usage/ and
// draws whatever record appears there, whoever wrote it (see the panel's
// plugins/agents/README.md). This service is that writer for ollamux: on a
// timer it runs the bundled collector, validates the JSON it prints, and
// publishes it into the usage directory atomically — exactly the record
// omarchy-agent-usage-update would have written for a built-in agent.
//
// The cadence is short because the record carries live load info (the hero
// line reads the proxy's slot table): the panel re-renders whatever record
// lands in the watched directory, so publish frequency IS text freshness.
// Each publish costs one short read-only SQLite scan and one in-memory
// proxy read; the /api/usage upstream probe is throttled separately by
// OLLAMUX_LIMITS_PROBE_MIN_INTERVAL, set below so a fast cadence does not
// multiply upstream requests.
//
// Running inside omarchy-shell means the shell's own lifecycle owns this:
// omarchy plugin enable/disable/add/remove is the whole install story, with
// no sudo copy and no side systemd unit competing with the panel's timer.
Item {
  id: root

  // Stamped in by the shell when it mounts a service plugin; carries the
  // directory this plugin was installed into.
  property var manifest: null

  readonly property string sourceDir:
    manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string collector: sourceDir + "/collector/omarchy-agent-usage-ollamux"

  // The usage directory the panel watches, resolved the same way the panel
  // resolves it.
  readonly property string usageDir:
    (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") || "") + "/.local/state")
    + "/omarchy/agents/usage"

  // How often the record is republished; the panel watches the file, so this
  // is the freshness of the concurrency hero text (and every other number).
  readonly property int refreshIntervalSec: {
    var parsed = parseInt(Quickshell.env("OLLAMUX_PUBLISH_INTERVAL") || "", 10)
    return !isNaN(parsed) && parsed >= 5 ? parsed : 15
  }

  // The service publishes far faster than the default 15 s probe throttle
  // would like, so the child is told to throttle upstream /api/usage probes
  // to one per 10 minutes; token scans and the in-memory /_keys read stay
  // per-publish.
  readonly property int probeIntervalSec: {
    var parsed = parseInt(Quickshell.env("OLLAMUX_PROBE_INTERVAL") || "", 10)
    return !isNaN(parsed) && parsed >= 15 ? parsed : 600
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.publish()
  }

  Process {
    id: collect

    // Merged over the parent environment by Quickshell.
    environment: ({
      "OLLAMUX_LIMITS_PROBE_MIN_INTERVAL": String(root.probeIntervalSec)
    })

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publishRecord(text.trim())
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("ollamux.agents", text.trim())
    }
  }

  function publish() {
    if (root.collector === "" || collect.running) return
    collect.command = [root.collector]
    collect.running = true
  }

  // Same publication contract as omarchy-agent-usage-update: validate with
  // jq, then land the file atomically so the panel never sees a half record.
  function publishRecord(record) {
    var trimmed = String(record || "").trim()
    if (trimmed === "") return
    publishProcess.command = [
      "bash", "-c",
      "record=$1; usage_dir=$2; "
        + "printf '%s\\n' \"$record\" | jq -e . >/dev/null || exit 1; "
        + "mkdir -p \"$usage_dir\"; "
        + "tmp=$(mktemp \"$usage_dir/.ollamux.XXXXXX\"); "
        + "printf '%s\\n' \"$record\" >\"$tmp\"; "
        + "mv \"$tmp\" \"$usage_dir/ollamux.json\"",
      "ollamux-publish", trimmed, root.usageDir
    ]
    publishProcess.running = true
  }

  Process { id: publishProcess }
}