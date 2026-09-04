import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

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

// Live concurrency for the ollamux proxy, right in the bar: "2/6" means two
// of six request slots busy, "+1" after it when requests are queued. The
// numbers come from the proxy's own per-key slot table (GET /_keys), a pure
// in-memory read with no upstream traffic, so a short poll is honest rather
// than wasteful.
//
// Purely informational: no alarm colors, no popup, no IPC. The bar slot
// collapses to zero width whenever the label is empty — proxy unreachable,
// answer unusable, or no keys up — and reflows back when it returns.
BarWidget {
  id: root
  moduleName: "ollamux.agents"

  // Seconds between polls of the proxy's slot table.
  readonly property int pollIntervalSec: {
    var parsed = parseInt(setting("pollIntervalSec", ""), 10)
    return !isNaN(parsed) && parsed >= 2 ? parsed : 5
  }

  // Base URL of the ollamux proxy; "" falls back to the collector's default.
  readonly property string baseUrl: {
    var configured = String(setting("baseUrl", "") || "")
    if (configured !== "") return configured.replace(/\/+$/, "")
    var fromEnv = String(Quickshell.env("OLLAMUX_BASE_URL") || "")
    return fromEnv !== "" ? fromEnv.replace(/\/+$/, "") : "http://127.0.0.1:11435"
  }

  // "2/6" — active request slots over capacity. "" hides the widget.
  property string slotText: ""
  // Per-key tooltip lines, plus a queued note when requests are waiting.
  property string detailText: ""

  function refresh() {
    if (!keysProc.running) keysProc.running = true
  }

  function summarize(raw) {
    var rows
    try {
      rows = JSON.parse(String(raw || ""))
    } catch (e) {
      return
    }
    if (!Array.isArray(rows)) return

    var active = 0
    var capacity = 0
    var queued = 0
    var lines = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!row || typeof row !== "object") continue
      var state = String(row.state || "")
      var concurrency = Number(row.concurrency)
      var inUse = Number(row.in_use)
      var keyQueued = Number(row.waiters)
      if (!isFinite(inUse) || inUse < 0) inUse = 0
      if (!isFinite(keyQueued) || keyQueued < 0) keyQueued = 0
      var usable = state === "up" && isFinite(concurrency) && concurrency > 0
      if (usable) {
        capacity += concurrency
        active += inUse
      }
      queued += keyQueued
      var suffix = String(row.suffix || "key")
      var detail = suffix + " " + (usable ? inUse + "/" + concurrency : "—") + " " + state
      if (isFinite(row.waiters) && row.waiters > 0) detail += " (+" + row.waiters + " queued)"
      lines.push(detail)
    }

    if (capacity <= 0) {
      // No honest denominator: keys all dead (or none up). Hide rather than
      // show 0/0, which would read as idle.
      root.slotText = ""
      root.detailText = ""
      return
    }
    root.slotText = active + "/" + capacity
    if (queued > 0) {
      root.slotText += " +" + queued
      lines.push(queued + (queued === 1 ? " request" : " requests") + " queued")
    }
    root.detailText = lines.join("\n")
  }

  visible: slotText !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    interval: root.pollIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: keysProc
    command: ["curl", "-fsS", "--max-time", "3", root.baseUrl + "/_keys"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.summarize(text)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.slotText
    fontSize: Style.font.caption
    horizontalMargin: 6
    tooltipText: root.detailText
  }
}