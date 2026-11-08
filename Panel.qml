import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Detail popup for the Eight Sleep bar widget. Owns the data lifecycle (fetch,
// cache-aware refresh, notifications), the level/on-off controls, and the
// bed + last-night cards. All network access goes through bin/eightsleep-api.
Panel {
  id: root
  moduleName: "io.github.zuccs.eightsleep"
  ipcTarget: "io.github.zuccs.eightsleep"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot (BarWidget.qml), not this
  // nested panel, so everything the bar identifies a panel by has to be that
  // widget. Same arrangement as the first-party Weather panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh(false)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh(false)
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Settings (inline on this widget's shell.json entry) -----------------

  readonly property int refreshIntervalSec: Math.max(60, parseInt(setting("refreshIntervalSec", 300), 10) || 300)
  readonly property string units: String(setting("units", "C")) === "F" ? "F" : "C"
  readonly property string badgeShows: {
    var v = String(setting("badgeShows", "level"))
    return v === "temp" || v === "score" ? v : "level"
  }
  readonly property bool notificationsEnabled: String(setting("notifications", "On")) !== "Off"

  // ---- State ----------------------------------------------------------------

  // Absolute path of the bridge script, wherever this plugin was installed.
  readonly property string scriptPath: String(Qt.resolvedUrl("bin/eightsleep-api")).replace(/^file:\/\//, "")

  property var model: null           // last parsed response (Model.parseResponse)
  property string errorCode: ""
  property string errorMessage: ""
  property bool stale: false
  property double fetchedAt: 0
  property bool refreshing: false
  property bool everLoaded: false
  property var now: new Date()

  // Controls: the level the user is dialling towards, applied after a short
  // pause so a run of ↑↑↑ costs one request.
  property int pendingLevel: 0
  property bool hasPendingLevel: false
  property bool controlBusy: false
  property string controlError: ""

  readonly property var bed: model && model.ok ? model.bed : null
  readonly property var night: model && model.ok ? model.night : null
  readonly property int shownLevel: hasPendingLevel ? pendingLevel : (bed && bed.targetLevel !== null ? bed.targetLevel : 0)
  readonly property bool needsSetup: errorCode === "no-credentials"
  readonly property bool showingError: !needsSetup && errorCode !== "" && !stale
  readonly property string badgeText: bed ? Model.badgeText(model, badgeShows, units) : Model.BAR_GLYPH
  readonly property bool badgeUrgent: Model.badgeUrgent(model)
  readonly property bool badgeDimmed: !bed || (!bed.on && !badgeUrgent)
  readonly property string headline: needsSetup ? "Login needed"
    : (showingError && !bed ? "Unavailable"
    : (!everLoaded && !bed ? "Connecting…" : Model.summaryLine(model, units)))
  readonly property string tooltip: needsSetup ? "Eight Sleep · login not set"
    : (showingError && !bed ? "Eight Sleep · " + errorMessage
    : Model.summaryLine(model, units) + (night ? " · " + Model.nightSummary(night) : ""))
  readonly property string updatedText: {
    root.now // reactive dependency so relative times tick
    if (!root.fetchedAt) return ""
    var rel = Model.formatRelative(new Date(root.fetchedAt), root.now)
    if (root.stale) return (root.errorMessage || "Last refresh failed") + " — showing data from " + rel
    return "Updated " + rel
  }

  // Popup text sits on the popup background, so use the theme foreground (as
  // Weather does), not barForeground, which swaps to a contrast colour when the
  // bar itself is transparent.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Data lifecycle -------------------------------------------------------

  // force=false honours the on-disk cache (a panel open or shell restart costs
  // no API request); force=true always hits the API.
  property bool pendingRefresh: false
  property bool pendingForce: false

  function refresh(force) {
    if (fetchProc.running) {
      pendingRefresh = true
      pendingForce = pendingForce || force === true
      return
    }
    refreshing = true
    var maxAge = force ? "0" : String(Math.max(30, refreshIntervalSec - 30))
    fetchProc.command = [root.scriptPath, "state", "--max-age", maxAge]
    fetchProc.running = true
  }

  onRefreshingChanged: if (!refreshing) refreshButton.rotation = 0

  function applyRaw(raw) {
    var parsed = Model.parseResponse(raw)
    if (parsed.ok) {
      if (root.everLoaded && root.notificationsEnabled && !parsed.cached)
        root.notify(Model.diffModels(root.model, parsed))
      root.model = parsed
      root.fetchedAt = parsed.fetchedAt
      root.stale = parsed.stale
      root.errorCode = parsed.stale ? parsed.error : ""
      root.errorMessage = parsed.stale ? parsed.message : ""
      root.everLoaded = true
      // A fresh read supersedes whatever the user was dialling, unless a
      // control is still in flight.
      if (!root.controlBusy && !applyTimer.running) root.hasPendingLevel = false
    } else {
      root.errorCode = parsed.error || "unknown"
      root.errorMessage = parsed.message || "Something went wrong."
      // Keep whatever we last showed, but say so: a failed poll must not
      // present old data as current.
      root.stale = root.bed !== null
    }
    root.now = new Date()
  }

  // One bar surface exists per monitor, each with its own panel instance.
  // Route explicit refreshes through the host widget so every instance
  // updates; the bridge's lock makes that a single round of requests.
  function refreshAll() {
    if (root.hostWidget && typeof root.hostWidget.broadcast === "function") root.hostWidget.broadcast("refresh")
    else root.refresh(true)
  }

  function notify(changes) {
    for (var i = 0; i < changes.length; i++) {
      var n = Model.notificationFor(changes[i])
      Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Eight Sleep", "-g", n.glyph, "-u", n.urgency, n.headline, n.body])
    }
  }

  // ---- Controls -------------------------------------------------------------

  function adjustLevel(delta) {
    if (!root.bed || root.needsSetup) return
    root.pendingLevel = Model.stepLevel(root.shownLevel, delta)
    root.hasPendingLevel = true
    root.controlError = ""
    applyTimer.restart()
  }

  function applyPendingLevel() {
    if (!root.hasPendingLevel) return
    runControl(["set-level", String(root.pendingLevel)])
  }

  function toggleSide() {
    if (!root.bed || root.needsSetup) return
    applyTimer.stop()
    root.hasPendingLevel = false
    runControl([root.bed.on ? "off" : "on"])
  }

  function runControl(args) {
    if (controlProc.running) {
      // A control is in flight; re-run once it lands so the last intent wins.
      root.queuedControl = args
      return
    }
    root.controlBusy = true
    root.controlError = ""
    controlProc.command = [root.scriptPath].concat(args)
    controlProc.running = true
  }
  property var queuedControl: null

  function copySetupCommand(index) {
    Quickshell.execDetached(["wl-copy", Model.SETUP_COMMANDS[index]])
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Eight Sleep", "-g", Model.GLYPH.key, "Command copied", "Paste it in a terminal, then press r in the panel"])
  }

  Process {
    id: fetchProc
    running: false
    command: []
    stdout: StdioCollector { id: fetchStdout; waitForEnd: true; onStreamFinished: root._fetchOutput = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var raw = String(fetchStdout.text || root._fetchOutput || "").trim()
      root._fetchOutput = ""
      if (!raw) {
        root.errorCode = "bridge"
        root.errorMessage = "eightsleep-api produced no output (exit " + exitCode + "). Is it executable?"
        root.stale = root.bed !== null
      } else {
        root.applyRaw(raw)
      }
      if (root.pendingRefresh) {
        var force = root.pendingForce
        root.pendingRefresh = false
        root.pendingForce = false
        Qt.callLater(function() { root.refresh(force) })
      }
    }
  }
  property string _fetchOutput: ""

  Process {
    id: controlProc
    running: false
    command: []
    stdout: StdioCollector { id: controlStdout; waitForEnd: true; onStreamFinished: root._controlOutput = text }
    onExited: function(exitCode) {
      var raw = String(controlStdout.text || root._controlOutput || "").trim()
      root._controlOutput = ""
      var result = null
      try { result = JSON.parse(raw) } catch (e) { result = null }
      root.controlBusy = false
      if (result && result.ok === true) {
        root.controlError = ""
      } else {
        root.controlError = result && result.message ? Model.trim(result.message, 300) : "eightsleep-api produced no output (exit " + exitCode + ")."
        root.hasPendingLevel = false
      }
      if (root.queuedControl) {
        var next = root.queuedControl
        root.queuedControl = null
        Qt.callLater(function() { root.runControl(next) })
        return
      }
      // The bridge dropped its cache; every monitor re-reads the new target.
      root.refreshAll()
    }
  }
  property string _controlOutput: ""

  Timer {
    id: applyTimer
    interval: 700
    repeat: false
    onTriggered: root.applyPendingLevel()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // Relative timestamps tick while the panel is open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.now = new Date()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll() }
    function toggleSide(): void { root.toggleSide() }
    function warmer(): void { root.adjustLevel(Model.LEVEL_STEP) }
    function cooler(): void { root.adjustLevel(-Model.LEVEL_STEP) }
  }

  // ---- UI -------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        // Up/right = warmer, down/left = cooler, one app step per press.
        if (dy !== 0) root.adjustLevel(-dy * Model.LEVEL_STEP)
        else if (dx !== 0) root.adjustLevel(dx * Model.LEVEL_STEP)
      }
      onActivateRequested: root.toggleSide()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") root.refreshAll()
        else if (t === "t") root.toggleSide()
        else if (t === "+" || t === "=" || t === "k") root.adjustLevel(Model.LEVEL_STEP)
        else if (t === "-" || t === "_" || t === "j") root.adjustLevel(-Model.LEVEL_STEP)
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(10)

        // ---- Header: glyph, title, one-line summary, refresh.
        Item {
          width: parent.width
          height: Math.max(headerLeft.implicitHeight, refreshButton.height)

          Row {
            id: headerLeft
            anchors.left: parent.left
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(12)

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.badgeUrgent && root.model ? root.model.alerts[0].glyph : (root.bed ? root.bed.glyph : Model.BAR_GLYPH)
              color: root.badgeUrgent ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: headerLeft.width - Style.font.display - headerLeft.spacing
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "EIGHT SLEEP" + (root.model && root.model.firstName ? " · " + root.model.firstName.toUpperCase() : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.headline
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                elide: Text.ElideRight
              }
            }
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Refresh (r)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !root.refreshing && !root.needsSetup
            onClicked: root.refreshAll()

            RotationAnimator on rotation {
              running: root.refreshing
              from: 0; to: 360
              duration: 900
              loops: Animation.Infinite
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        // ---- Setup: no login in the keyring yet.
        Column {
          visible: root.needsSetup
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "This widget signs in to Eight Sleep with the same email and password as the app. Store both in your keyring — secret-tool prompts for each value so it never touches your shell history:"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: Model.SETUP_COMMANDS

            delegate: Rectangle {
              id: setupRow
              required property string modelData
              required property int index
              width: parent.width
              height: setupCommand.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, Color.accent)

              Text {
                id: setupCommand
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: copyButton.left
                anchors.margins: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: setupRow.modelData
                wrapMode: Text.WrapAnywhere
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              PanelActionButton {
                id: copyButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                iconText: Model.GLYPH.copy
                tooltipText: "Copy command"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.copySetupCommand(setupRow.index)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Press r here once both are stored. Your password is only ever sent to auth-api.8slp.net to obtain a token, which is cached in ~/.local/state/omarchy/eightsleep."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- Error with nothing cached to show.
        Text {
          textFormat: Text.PlainText
          visible: root.showingError && !root.bed
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.errorMessage
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // ---- Bed card: state, big level, controls.
        Rectangle {
          visible: root.bed !== null
          width: parent.width
          height: bedContent.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, Color.accent)

          Column {
            id: bedContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(12)

              // Big level readout.
              Column {
                id: levelColumn
                width: Style.space(120)
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: root.bed && (root.bed.on || root.hasPendingLevel) ? Model.formatLevel(root.shownLevel) : "Off"
                  color: root.hasPendingLevel ? root.accent : (root.bed && root.bed.on ? root.foreground : root.dim)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display * 1.6
                  font.weight: Font.Medium
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: {
                    if (!root.bed) return ""
                    if (root.hasPendingLevel) return "≈ " + Model.formatTemp(root.shownLevel, root.units) + (root.controlBusy ? " · applying…" : "")
                    if (!root.bed.on) return root.bed.deviceLevel !== null ? "now " + Model.formatTemp(root.bed.deviceLevel, root.units) : ""
                    var s = "≈ " + Model.formatTemp(root.bed.targetLevel, root.units)
                    if (root.bed.deviceLevel !== null && Model.levelToTemp(root.bed.deviceLevel, root.units) !== Model.levelToTemp(root.bed.targetLevel, root.units))
                      s += " · now " + Model.formatTemp(root.bed.deviceLevel, root.units)
                    return s
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              // Status lines.
              Column {
                width: parent.width - levelColumn.width - controlsColumn.width - parent.spacing * 2
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: {
                    if (!root.bed) return ""
                    if (!root.bed.on) return root.bed.label + " is off"
                    var d = root.bed.direction
                    return d === "heating" ? "Warming" : (d === "cooling" ? "Cooling" : "Holding temperature")
                  }
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: text !== ""
                  text: {
                    if (!root.bed) return ""
                    var bits = []
                    if (root.bed.on && root.bed.autopilot) bits.push(root.bed.autopilot === "on" ? "Autopilot" : "Autopilot · " + root.bed.autopilot)
                    if (root.bed.on && root.bed.remainingSec) bits.push(Model.formatDuration(root.bed.remainingSec) + " left")
                    if (root.bed.inBed) bits.push("In bed")
                    else if (root.bed.lastInBed) {
                      root.now
                      bits.push("Last in bed " + Model.formatRelative(root.bed.lastInBed, root.now))
                    }
                    return bits.join(" · ")
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: root.controlError !== ""
                  text: root.controlError
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              // Controls: warmer / cooler / power.
              Column {
                id: controlsColumn
                width: powerButton.width
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                PanelActionButton {
                  iconText: "󰐕"
                  tooltipText: "Warmer (↑ or +)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !!root.bed && root.shownLevel < Model.LEVEL_MAX
                  onClicked: root.adjustLevel(Model.LEVEL_STEP)
                }
                PanelActionButton {
                  iconText: "󰍴"
                  tooltipText: "Cooler (↓ or −)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !!root.bed && root.shownLevel > Model.LEVEL_MIN
                  onClicked: root.adjustLevel(-Model.LEVEL_STEP)
                }
                PanelActionButton {
                  id: powerButton
                  iconText: Model.GLYPH.off
                  tooltipText: root.bed && root.bed.on ? "Turn side off (t)" : "Turn side on (t)"
                  foreground: root.bed && root.bed.on ? root.accent : root.foreground
                  fontFamily: root.fontFamily
                  enabled: !!root.bed && !root.controlBusy
                  onClicked: root.toggleSide()
                }
              }
            }

            // Autopilot schedule levels, when the API reports them.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: !!root.bed && !!root.bed.smart && root.bed.smart.bedTime !== null
              text: root.bed && root.bed.smart
                ? "Autopilot · bedtime " + Model.formatLevel(root.bed.smart.bedTime)
                  + " → early " + Model.formatLevel(root.bed.smart.initialSleep)
                  + " → late " + Model.formatLevel(root.bed.smart.finalSleep)
                : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        // ---- Alerts: offline / water / priming.
        Repeater {
          model: root.model && root.model.ok ? root.model.alerts : []

          delegate: Row {
            required property var modelData
            width: contentColumn.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: modelData.glyph
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.text
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        // ---- Last night.
        Column {
          visible: root.bed !== null
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: {
                root.now
                return (root.night && root.night.start ? Model.formatNightLabel(root.night.start, root.now) : "Last night").toUpperCase()
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
            Text {
              textFormat: Text.PlainText
              text: root.night && root.night.start ? Model.timeRange(root.night.start, root.night.end) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.night
            text: "No sleep data yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.italic: true
          }

          Row {
            visible: root.night !== null
            width: parent.width
            spacing: Style.space(14)

            // Score.
            Column {
              id: scoreColumn
              width: Style.space(72)
              spacing: 0

              Text {
                textFormat: Text.PlainText
                text: root.night && root.night.score !== null ? String(root.night.score) : "–"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display * 1.6
                font.weight: Font.Medium
              }
              Text {
                textFormat: Text.PlainText
                text: root.night && root.night.processing ? "so far" : "score"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Duration, stage bar, vitals.
            Column {
              width: parent.width - scoreColumn.width - parent.spacing
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: {
                  if (!root.night) return ""
                  var s = Model.nightSummary(root.night)
                  if (!root.night.processing && root.night.sleepSec !== null && root.night.presenceSec !== null)
                    s = Model.formatDuration(root.night.sleepSec) + " asleep · " + Model.formatDuration(root.night.presenceSec) + " in bed"
                  return s
                }
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              // Stacked stage bar: deep, REM, light, awake.
              Item {
                id: stageBar
                width: parent.width
                height: Style.space(8)
                visible: !!root.night && !!(root.night.stages.light || root.night.stages.deep || root.night.stages.rem)
                readonly property var fractions: Model.stageFractions(root.night)

                Row {
                  anchors.fill: parent
                  spacing: 1
                  Rectangle { height: parent.height; width: stageBar.width * stageBar.fractions.deep;  radius: 2; color: root.accent }
                  Rectangle { height: parent.height; width: stageBar.width * stageBar.fractions.rem;   radius: 2; color: Qt.lighter(root.accent, 1.35) }
                  Rectangle { height: parent.height; width: stageBar.width * stageBar.fractions.light; radius: 2; color: Style.hoverFillFor(root.foreground, Color.accent) }
                  Rectangle { height: parent.height; width: stageBar.width * stageBar.fractions.awake; radius: 2; color: "transparent"; border.width: 1; border.color: root.dim }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: stageBar.visible
                text: {
                  if (!root.night) return ""
                  var st = root.night.stages
                  var bits = []
                  if (st.deep !== null) bits.push("deep " + Model.formatDuration(st.deep))
                  if (st.rem !== null) bits.push("REM " + Model.formatDuration(st.rem))
                  if (st.light !== null) bits.push("light " + Model.formatDuration(st.light))
                  if (st.awake !== null && st.awake > 0) bits.push("awake " + Model.formatDuration(st.awake))
                  return bits.join(" · ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: text !== ""
                text: {
                  if (!root.night) return ""
                  var n = root.night
                  var bits = []
                  if (n.heartRate !== null) bits.push(Model.GLYPH.heart + " " + Math.round(n.heartRate) + " bpm")
                  if (n.hrv !== null) bits.push("HRV " + Math.round(n.hrv))
                  if (n.respiratoryRate !== null) bits.push(Math.round(n.respiratoryRate * 10) / 10 + " br/min")
                  if (n.tossTurns !== null) bits.push(n.tossTurns + " tosses")
                  return bits.join(" · ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: text !== ""
                text: {
                  if (!root.night) return ""
                  var n = root.night
                  var bits = []
                  var f = root.units === "F"
                  if (n.roomTempC !== null) bits.push("room " + Math.round(f ? n.roomTempC * 9 / 5 + 32 : n.roomTempC) + " °" + (f ? "F" : "C"))
                  if (n.bedTempC !== null) bits.push("bed " + Math.round(f ? n.bedTempC * 9 / 5 + 32 : n.bedTempC) + " °" + (f ? "F" : "C"))
                  return bits.join(" · ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }

        // ---- Footer: freshness + key hints.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.everLoaded || root.stale

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.updatedText + (root.bed && root.bed.model && !root.stale ? " · " + root.bed.model : "")
            color: root.stale ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "↑↓ level · t on/off · r refresh · Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
