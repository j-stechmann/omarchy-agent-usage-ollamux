import QtQuick
import Quickshell
import Quickshell.Io

// The data side of the Ollamux agent tab. The built-in omarchy.agents panel
// is strictly a display: it watches ~/.local/state/omarchy/agents/usage/ and
// draws whatever record appears there, whoever wrote it (see the panel's
// plugins/agents/README.md). This service is that writer for ollamux: on a
// timer it runs the bundled collector, validates the JSON it prints, and
// publishes it into the usage directory atomically — exactly the record
// omarchy-agent-usage-update would have written for a built-in agent.
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

  // Match the panel's default cadence. Overlap with the panel refresh is
  // harmless rather than wasteful: the collector dedups concurrent runs and
  // throttles limits probes on its own.
  property int refreshIntervalSec: 900

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.publish()
  }

  Process {
    id: collect

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