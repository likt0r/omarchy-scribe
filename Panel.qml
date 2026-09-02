import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Scribe: correct the marked text, put it on the clipboard.
//
// One entry point covers both surfaces, the way the first-party popup widgets
// do -- `Ui.Panel` owns the open/close lifecycle, this file owns the bar
// button, the run state, and the panel content.
//
// The `scribe` CLI does the work and is the only writer of the history file;
// this panel reads that file through a watching FileView. Two writers would
// race whenever a correction landed with the panel open.
Panel {
  id: root
  moduleName: "likt0r.scribe"
  ipcTarget: "likt0r.scribe"
  // The base handler covers open/close/toggle; correct() and cancel() are
  // ours, and IpcHandler allows one handler per target.
  manageIpc: false

  // ------------------------------------------------------------- settings

  readonly property string backend: setting("backend", "anthropic")
  readonly property string model: setting("model", "claude-opus-5")
  readonly property string endpoint: setting("endpoint", "")
  readonly property string profile: setting("profile", "Grammar")
  readonly property int timeoutSec: setting("timeoutSec", 30)
  readonly property bool clipboardFallback: setting("clipboardFallback", true)
  readonly property bool notifyOnDone: setting("notify", true)
  readonly property bool historyEnabled: setting("historyEnabled", true)
  readonly property bool historyStoreText: setting("historyStoreText", true)
  readonly property int historyLimit: setting("historyLimit", 50)

  // Ui.Panel does not carry the bar geometry that Ui.BarWidget does, and the
  // icon needs it: "Aa" does not fit a vertical bar's width.
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/scribe"
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/omarchy/scribe"

  // ------------------------------------------------------------ run state

  // Not `state`: Item already owns that name for QML state groups, and
  // shadowing it makes every Behavior in the file behave oddly.
  property string runState: Model.STATE_IDLE
  property string lastError: ""
  property int lastExitCode: 0
  property var lastResult: null

  readonly property bool busy: Model.isBusy(runState)

  function apply(event) {
    runState = Model.nextState(runState, event)
    if (runState === Model.STATE_DONE) doneTimer.restart()
  }

  function correct() {
    // A second keypress mid-flight is deliberately ignored rather than
    // queued: two adapters racing to wl-copy would leave the clipboard with
    // whichever finished last, which need not be the one being waited for.
    if (busy) return
    broadcast("markWorking")
    lastError = ""
    correctProc.command = commandFor()
    correctProc.running = true
  }

  function markWorking() { apply("start") }

  function cancel() {
    if (!busy) return
    correctProc.running = false
    broadcast("markCancelled")
  }

  function markCancelled() { apply("cancel") }

  function commandFor() {
    var argv = [
      pluginDir + "/scribe", "run", "--json",
      "--backend", backend,
      "--model", model,
      "--profile", profile,
      "--timeout", String(timeoutSec),
      "--history-limit", String(historyLimit)
    ]
    if (endpoint !== "") argv = argv.concat(["--endpoint", endpoint])
    if (!clipboardFallback) argv.push("--no-clipboard-fallback")
    if (!notifyOnDone) argv.push("--no-notify")
    if (!historyEnabled) argv.push("--no-history")
    else if (!historyStoreText) argv.push("--history-metadata-only")
    return argv
  }

  // A bar surface exists per monitor, so a state change set on one instance
  // would leave the others painting a stale spinner. Every transition goes
  // out through the base class's broadcast().
  function broadcast(method) {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i][method] === "function") items[i][method]()
    }
  }

  function succeed(result) {
    lastResult = result
    lastExitCode = 0
    lastError = ""
    apply("succeed")
  }

  function fail(code, stderr) {
    lastExitCode = code
    lastError = Model.errorMessage(code, stderr)
    apply("fail")
  }

  // ---------------------------------------------------------- panel state

  property int tabIndex: 0            // 0 = history, 1 = settings
  property int expandedIndex: -1
  property var history: []
  property var profileNames: []
  property var backendNames: []
  property string doctorReport: ""

  function refresh() {
    historyFile.reload()
    profilesProc.running = true
    backendsProc.running = true
  }

  function updateSetting(key, value) {
    var entry = { id: moduleName }
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    entry[key] = value
    // Applied locally first so a dropdown does not snap back while the write
    // round-trips through shell.json.
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function copyEntry(entry) {
    if (!Model.hasText(entry)) return
    copyProc.text = entry.corrected
    copyProc.running = true
  }

  // ------------------------------------------------------------- plumbing

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    // Opening the panel is the acknowledgement of a sticky error.
    if (runState === Model.STATE_ERROR) apply("acknowledge")
    expandedIndex = -1
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    id: doneTimer
    interval: Model.DONE_HOLD_MS
    onTriggered: root.apply("settle")
  }

  Process {
    id: correctProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) {
        var result = null
        try { result = JSON.parse(stdout.text) } catch (e) { result = null }
        root.broadcastResult(result)
      } else {
        root.broadcastFailure(exitCode, stderr.text)
      }
      root.historyFile.reload()
    }
  }

  // Results carry data, so they cannot ride on the argument-free broadcast().
  function broadcastResult(result) {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++)
      if (items[i] && typeof items[i].succeed === "function") items[i].succeed(result)
  }

  function broadcastFailure(code, stderr) {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++)
      if (items[i] && typeof items[i].fail === "function") items[i].fail(code, stderr)
  }

  Process {
    id: copyProc
    property string text: ""
    running: false
    command: ["wl-copy", "--", copyProc.text]
  }

  Process {
    id: clearProc
    running: false
    command: [root.pluginDir + "/scribe", "history", "clear"]
    onExited: root.historyFile.reload()
  }

  Process {
    id: profilesProc
    running: false
    command: [root.pluginDir + "/scribe", "profiles", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.profileNames = (parsed.profiles || []).map(function(p) { return p.name })
        } catch (e) { root.profileNames = [] }
      }
    }
  }

  Process {
    id: backendsProc
    running: false
    command: [root.pluginDir + "/scribe", "backends", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.backendNames = JSON.parse(text).backends || [] }
        catch (e) { root.backendNames = [] }
      }
    }
  }

  Process {
    id: doctorProc
    running: false
    command: root.endpoint === ""
      ? [root.pluginDir + "/scribe", "doctor", "--backend", root.backend]
      : [root.pluginDir + "/scribe", "doctor", "--backend", root.backend, "--endpoint", root.endpoint]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.doctorReport = text }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: editProc
    running: false
    command: ["xdg-open", root.configDir + "/profiles.json"]
  }

  FileView {
    id: historyFile
    path: root.stateDir + "/history.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.history = parsed.entries || []
      } catch (e) { root.history = [] }
    }
    onLoadFailed: root.history = []
  }

  IpcHandler {
    target: root.ipcTarget

    function correct(): void { root.correct() }
    function cancel(): void { root.cancel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return root.runState }

    // Why the last run failed, without opening the panel. The icon can only
    // say "something broke"; this is what makes a failure diagnosable from a
    // terminal or a script.
    function lastError(): string { return root.lastError }
    function lastExit(): string { return String(root.lastExitCode) }
    function command(): string { return root.commandFor().join(" ") }
  }

  // ----------------------------------------------------------- bar button

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property color markColor: runState === Model.STATE_ERROR ? urgent
    : runState === Model.STATE_DONE ? accent
    : barForeground

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // Drawn rather than set as a glyph. The bar font is whatever the theme
    // says it is, and a Nerd Font codepoint that renders on one machine as a
    // spellcheck mark renders on another as a box. "Aa" over a rule is
    // legible in any font, and the rule doubles as the progress indicator.
    iconComponent: Component {
      Item {
        implicitWidth: Style.bar.iconCanvas
        implicitHeight: Style.bar.iconCanvas

        Column {
          anchors.centerIn: parent
          spacing: Math.max(1, Style.space(2))

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.vertical ? "A" : "Aa"
            color: root.runState === Model.STATE_ERROR ? root.urgent : root.barForeground
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            opacity: root.busy ? 0.55 : 1.0
            Behavior on opacity { NumberAnimation { duration: 150 } }
          }

          // The rule under the letters: solid at rest, a sweeping segment
          // while a correction is in flight, accent on success, urgent on
          // failure. One element carries all four states, so the icon never
          // changes size or jumps position between them.
          Item {
            id: rule
            width: Math.max(Style.space(10), Style.bar.iconCanvas * 0.75)
            height: Math.max(1, Style.space(2))

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: root.markColor
              opacity: root.busy ? 0.2 : 1.0
              Behavior on color { ColorAnimation { duration: 160 } }
              Behavior on opacity { NumberAnimation { duration: 150 } }
            }

            Rectangle {
              id: sweep
              visible: root.busy
              width: parent.width * 0.4
              height: parent.height
              radius: height / 2
              color: root.accent

              XAnimator on x {
                running: root.busy
                loops: Animation.Infinite
                from: 0
                to: rule.width - sweep.width
                duration: 700
                easing.type: Easing.InOutSine
              }
            }
          }
        }
      }
    }

    onPressed: function(buttonCode) {
      // Left click is the panel, because that is what a bar icon with a
      // popup means. Middle click runs a correction without opening
      // anything -- the mouse equivalent of the keybind.
      if (buttonCode === Qt.MiddleButton) root.correct()
      else if (buttonCode === Qt.RightButton) root.cancel()
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "c" || t === "C") root.correct()
        else if (t === "h" || t === "H") root.tabIndex = 0
        else if (t === "s" || t === "S") root.tabIndex = 1
        else if (t === "d" || t === "D") { root.tabIndex = 1; doctorProc.running = true }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Scribe"
            meta: root.busy ? "Correcting…"
              : root.runState === Model.STATE_ERROR ? "Last run failed"
              : root.history.length > 0 ? Model.summarize(root.profile + " · " + root.model, 44)
              : "Mark text, then press the keybind"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // The error is the first thing in the panel because opening the
          // panel is usually the reaction to seeing the icon go red.
          Text {
            visible: root.lastError !== ""
            width: parent.width
            text: root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ButtonGroup {
            width: parent.width
            options: [{ value: "history", label: "History" }, { value: "settings", label: "Settings" }]
            value: root.tabIndex === 0 ? "history" : "settings"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(v) { root.tabIndex = v === "history" ? 0 : 1 }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------------ history

          Column {
            visible: root.tabIndex === 0
            width: parent.width
            spacing: Style.space(8)

            Text {
              visible: root.history.length === 0
              width: parent.width
              text: root.historyEnabled
                ? "No corrections yet."
                : "History is switched off."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.history
                HistoryRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  entry: modelData
                  rowIndex: index
                }
              }
            }

            Button {
              visible: root.history.length > 0
              text: "Clear history"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: confirmClear.opened = true
            }
          }

          // ----------------------------------------------------- settings

          Column {
            visible: root.tabIndex === 1
            width: parent.width
            spacing: Style.space(10)

            Dropdown {
              width: parent.width
              label: "Backend"
              value: root.backend
              options: root.backendNames
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) { root.updateSetting("backend", v) }
            }

            Dropdown {
              width: parent.width
              label: "Prompt profile"
              value: root.profile
              options: root.profileNames
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) { root.updateSetting("profile", v) }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap

              PanelSectionHeader {
                text: "MODEL"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              TextField {
                width: parent.width
                text: root.model
                foreground: root.foreground
                onEditingFinished: if (text !== root.model) root.updateSetting("model", text)
              }

              Text {
                width: parent.width
                text: "Passed to the backend verbatim. claude-haiku-4-5 is the cheaper, faster choice."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // Only the openai backend takes one, so the field stays out of
            // the way until that backend is the one selected.
            Column {
              visible: root.backend === "openai"
              width: parent.width
              spacing: Style.spacing.labelGap

              PanelSectionHeader {
                text: "ENDPOINT"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              TextField {
                width: parent.width
                text: root.endpoint
                foreground: root.foreground
                onEditingFinished: if (text !== root.endpoint) root.updateSetting("endpoint", text)
              }

              Text {
                width: parent.width
                text: "OpenAI-compatible base URL, e.g. http://gpu-box.local:11434/v1 for a remote ollama. Empty means api.openai.com."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            PanelSeparator { foreground: root.foreground }

            Toggle {
              width: parent.width
              label: "Fall back to the clipboard"
              description: "When nothing is marked, correct what is on the clipboard."
              checked: root.clipboardFallback
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.updateSetting("clipboardFallback", !root.clipboardFallback)
            }

            Toggle {
              width: parent.width
              label: "Notify when done"
              checked: root.notifyOnDone
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.updateSetting("notify", !root.notifyOnDone)
            }

            Toggle {
              width: parent.width
              label: "Keep a history"
              description: "Corrections are stored in " + root.stateDir + "."
              checked: root.historyEnabled
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.updateSetting("historyEnabled", !root.historyEnabled)
            }

            Toggle {
              width: parent.width
              enabled: root.historyEnabled
              opacity: root.historyEnabled ? 1.0 : 0.5
              label: "Store the text in history"
              description: "Off records that a correction happened without writing its text to disk."
              checked: root.historyStoreText
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.updateSetting("historyStoreText", !root.historyStoreText)
            }

            PanelSeparator { foreground: root.foreground }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Check setup"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: doctorProc.running = true
              }

              Button {
                text: "Edit profiles"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: editProc.running = true
              }
            }

            Text {
              visible: root.doctorReport !== ""
              width: parent.width
              text: root.doctorReport
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: confirmClear
      anchors.fill: parent
      message: "Delete every stored correction?"
      confirmText: "Clear"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onConfirmed: { clearProc.running = true; opened = false }
      onCanceled: opened = false
    }
  }

  // --------------------------------------------------------- history row

  component HistoryRow: CursorSurface {
    id: row
    property var entry: null
    property int rowIndex: 0

    readonly property bool expanded: root.expandedIndex === rowIndex
    readonly property bool textual: Model.hasText(entry)

    hasCursor: false
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: row.textual ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.expandedIndex = row.expanded ? -1 : row.rowIndex
    }

    ColumnLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(3)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          Layout.fillWidth: true
          text: row.textual
            ? Model.summarize(row.entry.corrected, 52)
            : (row.entry && row.entry.changed ? "Corrected" : "No changes") +
              " · " + (row.entry ? row.entry.correctedLength : 0) + " characters"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        PanelActionButton {
          visible: row.textual
          iconText: "󰆏"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.copyEntry(row.entry)
        }
      }

      Text {
        Layout.fillWidth: true
        text: {
          if (!row.entry) return ""
          var bits = [Qt.formatDateTime(new Date(row.entry.ts * 1000), "d MMM HH:mm")]
          if (row.entry.profile) bits.push(row.entry.profile)
          if (row.entry.model) bits.push(row.entry.model)
          var d = Model.formatDuration(row.entry.ms)
          if (d) bits.push(d)
          var u = Model.formatUsage(row.entry.usage)
          if (u) bits.push(u)
          if (!row.entry.changed) bits.push("unchanged")
          return bits.join(" · ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      // Both versions, so the panel answers "what did it actually change?"
      // without a diff algorithm having to be right about word boundaries.
      Column {
        visible: row.expanded && row.textual
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          width: parent.width
          text: row.entry ? row.entry.original : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: row.entry ? row.entry.corrected : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
