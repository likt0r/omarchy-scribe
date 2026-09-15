import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
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
  readonly property string effort: setting("effort", "")
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

  // The keybind now asks which prompt to use instead of assuming one. The
  // mouse path and the scriptable path still run straight away -- see
  // correctNow() -- because neither has a keyboard in hand to answer with.
  function correct() {
    openPicker()
  }

  function correctNow() {
    correctWith("")
  }

  // Run a one-off instruction instead of a stored prompt. The CLI wraps it in
  // the rules that keep the selection quarantined as data; this side only
  // refuses an empty one early so the UI and a script answer alike.
  function correctCustom(instruction) {
    var text = String(instruction || "").trim()
    if (text === "") return
    correctWith("", text)
  }

  // `profileOverride` is the picker's answer, empty for "whatever the
  // settings say". It never touches the stored setting: see activatePicker().
  function correctWith(profileOverride, instructionOverride) {
    // A second keypress mid-flight is deliberately ignored rather than
    // queued: two adapters racing to wl-copy would leave the clipboard with
    // whichever finished last, which need not be the one being waited for.
    if (busy) return
    // Marked here rather than in correct(): with a picker in front of the
    // run, marking on the keypress would sweep the bar rule for as long as
    // the user takes to choose, which reads as a correction already underway.
    broadcast("markWorking")
    lastError = ""
    correctProc.command = commandFor(profileOverride, instructionOverride)
    correctProc.running = true
  }

  function markWorking() { apply("start") }

  function cancel() {
    // Cancel means "stop what you started", and an open picker is the first
    // thing that qualifies. It also gives the overlay a way out that does not
    // depend on its own key handling: right click on the icon, or the IPC
    // verb, dismisses it even if something inside the surface is wedged.
    if (pickerOpen) {
      closePicker()
      return
    }
    if (!busy) return
    correctProc.running = false
    broadcast("markCancelled")
  }

  function markCancelled() { apply("cancel") }

  function commandFor(profileOverride, instructionOverride) {
    var argv = [
      pluginDir + "/scribe", "run", "--json",
      "--backend", backend,
      "--model", model,
      "--profile", profileOverride ? profileOverride : profile,
      "--timeout", String(timeoutSec),
      "--history-limit", String(historyLimit)
    ]
    // The CLI lets an instruction win over the profile, so both can be passed
    // and the one that matters is unambiguous at the other end.
    if (instructionOverride) argv = argv.concat(["--instruction", instructionOverride])
    if (endpoint !== "") argv = argv.concat(["--endpoint", endpoint])
    if (effort !== "") argv = argv.concat(["--effort", effort])
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

  property int tabIndex: 0            // 0 = history, 1 = settings, 2 = prompts
  readonly property var tabValues: ["history", "settings", "prompts"]
  property int expandedIndex: -1
  property var history: []
  // The full {name, title, system} objects, not just the names: the picker
  // shows titles, the Prompts tab edits the text, and both need what the CLI
  // already sends.
  property var profiles: []
  property var backendNames: []
  property string doctorReport: ""

  readonly property var profileOptions: profiles.map(function(p) {
    return { value: p.name, label: p.title || p.name }
  })

  function refresh() {
    historyFile.reload()
    profilesProc.running = true
    backendsProc.running = true
  }

  // ---------------------------------------------------------- prompt picker

  property bool pickerOpen: false
  property int pickerIndex: 0
  property string pendingProfile: ""
  property string pendingInstruction: ""
  property bool pickerWanted: false

  // "grid" picks a saved prompt, "compose" types a one-off instruction.
  property string pickerMode: "grid"
  // Remembered for the next open, in memory only. Persisting it would mean a
  // new manifest key -- defaults, schema and a literal setting() read, all
  // three gated by the suite -- for a string nobody asked to keep past a
  // shell restart.
  property string lastInstruction: ""

  // One more tile than there are prompts: the last one composes a one-off.
  readonly property int pickerCount: profiles.length + 1
  readonly property int pickerColumns: Model.gridColumns(pickerCount)

  // The profiles are read when the panel opens, but the keybind reaches a
  // shell where that may never have happened. Loading them up front means the
  // first press of the day shows a grid instead of nothing.
  Component.onCompleted: profilesProc.running = true

  function openPicker() {
    if (busy) return
    if (profiles.length === 0) {
      // Nothing to show yet: remember the ask and let the load finish it.
      pickerWanted = true
      profilesProc.running = true
      return
    }
    // Two layer surfaces both asking for exclusive keyboard focus is a fight
    // neither wins, and the panel is the one that can wait.
    if (opened) close()
    pickerMode = "grid"
    pickerIndex = Math.max(0, profiles.map(function(p) { return p.name }).indexOf(profile))
    pickerOpen = true
    Qt.callLater(function() { pickerKeys.forceActiveFocus() })
  }

  function closePicker() {
    pickerOpen = false
    pickerMode = "grid"
  }

  function movePicker(dx, dy) {
    pickerIndex = Model.moveIndex(pickerIndex, dx, dy, pickerCount, pickerColumns)
  }

  function activatePicker() {
    // The last tile is the composer, not a prompt.
    if (pickerIndex >= profiles.length) {
      openCompose()
      return
    }
    var chosen = profiles[pickerIndex]
    if (!chosen) return
    // Remembered as the new default, so the next "keybind, Enter" repeats
    // this choice. updateEntryInline diffs before persisting, so re-picking
    // the same prompt writes nothing.
    if (chosen.name !== profile) updateSetting("profile", chosen.name)
    pendingProfile = chosen.name
    // The surface goes first, the work second. An exclusive layer surface
    // swallows what Hyprland is asked to do underneath it (the lesson from
    // likt0r.overview), and a notification raised behind a full-screen
    // overlay is a notification nobody sees.
    pickerOpen = false
    pickerRun.restart()
  }

  function openCompose() {
    pickerMode = "compose"
    // Prefilled with the last one and selected, so repeating it is Enter and
    // replacing it is typing -- neither costs a backspace.
    instructionArea.text = lastInstruction
    Qt.callLater(function() {
      instructionArea.forceActiveFocus()
      instructionArea.selectAll()
    })
  }

  function closeCompose() {
    pickerMode = "grid"
    Qt.callLater(function() { pickerKeys.forceActiveFocus() })
  }

  // A one-off instruction. The CLI frames it with the same four rules every
  // stored prompt carries -- see compose_custom() in `scribe` -- so this path
  // never hands raw typed words to the model as its system prompt.
  function runCustom(instruction) {
    var text = String(instruction || "").trim()
    if (text === "") return
    lastInstruction = text
    pendingInstruction = text
    pickerOpen = false
    pickerMode = "grid"
    pickerRun.restart()
  }

  Timer {
    id: pickerRun
    interval: 50
    onTriggered: {
      var chosen = root.pendingProfile
      var typed = root.pendingInstruction
      root.pendingProfile = ""
      root.pendingInstruction = ""
      if (typed !== "") root.correctCustom(typed)
      else root.correctWith(chosen)
    }
  }

  // ------------------------------------------------------------ prompt edits

  // The draft is the editor's state, kept apart from `profiles` so that
  // nothing reaches disk until Save. It survives the panel closing, because
  // root outlives the popup -- an accidental Escape must not throw away a
  // paragraph someone just wrote.
  property string draftName: ""
  property string draftTitle: ""
  property string draftIcon: ""
  property string draftSystem: ""
  property string promptsError: ""

  readonly property var draftProfile: {
    for (var i = 0; i < profiles.length; i++)
      if (profiles[i].name === draftName) return profiles[i]
    return null
  }

  readonly property bool draftIsNew: draftName !== "" && draftProfile === null

  readonly property bool promptsDirty: draftName !== ""
    && (draftIsNew
        || draftTitle !== draftProfile.title
        || draftIcon !== draftProfile.icon
        || draftSystem !== draftProfile.system)

  // The two rules every shipped prompt carries. A hand-written prompt that
  // drops them still saves -- it is the user's file -- but the editor says so,
  // because without them the selection stops being quarantined as data.
  readonly property bool draftGuarded: draftSystem.indexOf("<text>") >= 0
    && draftSystem.toLowerCase().indexOf("nothing else") >= 0

  function selectPrompt(name) {
    draftName = name
    var found = null
    for (var i = 0; i < profiles.length; i++)
      if (profiles[i].name === name) found = profiles[i]
    loadDraft(found ? found.title : "", found ? found.icon : "", found ? found.system : "")
  }

  // The editors are written to rather than bound. A `text:` binding onto the
  // draft survives only until the first keystroke -- typing assigns text
  // imperatively and breaks it -- after which selecting another prompt would
  // leave the previous one's words on screen.
  function loadDraft(title, icon, system) {
    draftTitle = title
    draftIcon = icon
    draftSystem = system
    promptsError = ""
    if (typeof titleField !== "undefined" && titleField) titleField.text = title
    if (typeof systemArea !== "undefined" && systemArea) systemArea.text = system
  }

  // Keeps the editor pointed at something real after a reload or a delete,
  // without disturbing an edit in progress.
  function syncDraft() {
    if (profiles.length === 0) return
    if (draftName === "" || (draftProfile === null && !promptsDirty))
      selectPrompt(profiles[0].name)
  }

  // Moves the editor to the next prompt in the list. An unsaved draft for a
  // prompt that is not in the list yet has nothing to step from, so it stays.
  function stepPrompt(delta) {
    if (profiles.length === 0 || draftIsNew) return
    var at = -1
    for (var i = 0; i < profiles.length; i++)
      if (profiles[i].name === draftName) at = i
    var next = Math.min(Math.max(at + delta, 0), profiles.length - 1)
    if (next !== at) selectPrompt(profiles[next].name)
  }

  function newPrompt() {
    // The name is generated once from the title and then frozen: it is what
    // shell.json and every history entry refer to, so a later rename of the
    // title must not orphan them.
    var title = "New prompt"
    draftName = Model.profileName(title, profiles)
    // Seeded from an existing prompt rather than blank, so a new one inherits
    // the two rules that keep the selection quarantined as data instead of
    // starting life without them.
    loadDraft(title, "", profiles.length > 0 ? profiles[0].system : "")
    tabIndex = 2
  }

  function savePrompts() {
    if (draftName === "" || draftTitle.trim() === "" || draftSystem.trim() === "") {
      promptsError = "A prompt needs a title and a text."
      return
    }
    var out = []
    var replaced = false
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name === draftName) {
        out.push({ name: draftName, title: draftTitle, icon: draftIcon, system: draftSystem })
        replaced = true
      } else {
        out.push(profiles[i])
      }
    }
    if (!replaced) out.push({ name: draftName, title: draftTitle, icon: draftIcon, system: draftSystem })
    writeProfiles(out)
  }

  function deletePrompt(name) {
    if (profiles.length <= 1) return
    var out = profiles.filter(function(p) { return p.name !== name })
    // The setting would otherwise point at a prompt that no longer exists,
    // and resolve_profile would quietly correct with the first one instead.
    if (profile === name) updateSetting("profile", out[0].name)
    draftName = ""
    writeProfiles(out)
  }

  function writeProfiles(list) {
    saveProc.payload = JSON.stringify({ profiles: list })
    saveProc.running = true
  }

  // ------------------------------------------------------------ icon picker

  // [glyph, name] pairs generated from the font by tools/generate-icons.py.
  // Loaded on first open rather than at startup: it is 300 KB that most
  // sessions never look at.
  property var icons: []
  property bool iconPickerOpen: false
  property string iconQuery: ""
  property int iconIndex: 0

  readonly property int iconColumns: 7

  readonly property var iconMatches: Model.filterIcons(icons, iconQuery, 400)

  function openIconPicker() {
    iconQuery = ""
    iconIndex = 0
    iconPickerOpen = true
    if (icons.length === 0) iconsFile.reload()
    Qt.callLater(function() { iconSearch.forceActiveFocus() })
  }

  function closeIconPicker() {
    iconPickerOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function moveIconCursor(dx, dy) {
    iconIndex = Model.moveIndex(iconIndex, dx, dy, iconMatches.length, iconColumns)
  }

  function pickIcon(glyph) {
    draftIcon = glyph
    closeIconPicker()
  }

  FileView {
    id: iconsFile
    path: root.pluginDir + "/icons.json"
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.icons = parsed.icons || []
      } catch (e) { root.icons = [] }
    }
    onLoadFailed: root.icons = []
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

  // ConfirmDialog carries no key handling of its own -- it exposes handleKey()
  // and expects the panel to route into it, the way the first-party clipboard
  // and menu panels do. Without this a confirmation can only be answered with
  // the mouse: Escape does not dismiss it and Enter does not confirm it.
  readonly property var openDialog:
    confirmDelete.opened ? confirmDelete : (confirmClear.opened ? confirmClear : null)

  function dialogCancel() { if (openDialog) openDialog.canceled() }
  function dialogToggle() { if (openDialog) openDialog.selectedIndex = openDialog.selectedIndex === 0 ? 1 : 0 }
  function dialogActivate() {
    if (!openDialog) return
    if (openDialog.selectedIndex === 0) openDialog.canceled()
    else openDialog.confirmed()
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
      onStreamFinished: root.adoptProfiles(text)
    }
  }

  // The CLI decides what a valid profile is; this side only has to agree with
  // it. Routing the answer through the same normalizer the tests cover means
  // the panel cannot hold a shape the CLI would reject on the next read.
  function adoptProfiles(payload) {
    var parsed = null
    try { parsed = JSON.parse(payload) } catch (e) { parsed = null }
    profiles = Model.normalizeProfiles(parsed)
    if (pickerIndex >= profiles.length) pickerIndex = Math.max(0, profiles.length - 1)
    syncDraft()
    if (pickerWanted && profiles.length > 0) {
      pickerWanted = false
      openPicker()
    }
  }

  // Saving goes through the CLI rather than writing the file from here:
  // write_private keeps it at 0600 and the replace atomic, and one writer
  // means one idea of what a valid profile is.
  Process {
    id: saveProc
    property string payload: ""
    running: false
    stdinEnabled: true
    command: [root.pluginDir + "/scribe", "profiles", "save"]
    onStarted: {
      write(saveProc.payload)
      saveProc.payload = ""
      stdinEnabled = false
    }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.promptsError = ""
        root.adoptProfiles(stdout.text)
      } else {
        root.promptsError = Model.errorMessage(exitCode, stderr.text)
      }
    }
  }

  // profiles.json is still hand-editable, and "Open profiles.json" invites
  // exactly that. Without this, an edit made while the panel is open would be
  // overwritten by the next Save from a stale in-memory list.
  FileView {
    id: profilesFile
    path: root.configDir + "/profiles.json"
    watchChanges: true
    printErrors: false
    onFileChanged: profilesProc.running = true
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

    // What the keybind calls: ask which prompt, then correct.
    function correct(): void { root.correct() }

    // The two paths that skip the picker. A script has no keyboard to answer
    // with, so it says up front which prompt it means -- or takes the default.
    function correctNow(): void { root.correctNow() }
    function correctWith(profile: string): void { root.correctWith(profile) }
    function correctCustom(instruction: string): void { root.correctCustom(instruction) }

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
      // Middle click still corrects outright. Someone reaching for the mouse
      // has already accepted the default prompt; handing them a keyboard grid
      // instead would be slower than what they had.
      if (buttonCode === Qt.MiddleButton) root.correctNow()
      else if (buttonCode === Qt.RightButton) root.cancel()
      else root.toggle()
    }
  }

  // --------------------------------------------------------------- picker

  // A second layer surface rather than a second plugin entry point: adding
  // "overlay" to the manifest's kinds would reroute summon/hide/toggle away
  // from the bar widget (shell.qml's isBarWidgetPanelPlugin), and IpcHandler
  // allows one handler per target, which Panel.qml already holds. The picker
  // also needs commandFor(), the settings and the run state, all of which
  // live here.
  PanelWindow {
    id: picker

    visible: root.pickerOpen
    // One surface, on the monitor being looked at. A bar instance exists per
    // monitor and whichever one won the IPC registration opens the picker, so
    // without this the overlay could appear on a screen nobody is facing.
    screen: {
      var wanted = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name) : ""
      var screens = Quickshell.screens || []
      for (var i = 0; i < screens.length; i++)
        if (String(screens[i].name) === wanted) return screens[i]
      return null
    }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "likt0r-scribe-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.pickerOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    readonly property int gap: Style.space(12)
    readonly property int tileSize: Math.max(
      Style.space(120),
      Math.min(Style.space(200),
               Math.floor((picker.width * 0.6 - (root.pickerColumns - 1) * picker.gap) / root.pickerColumns)))
    // The block is centered on screen; the rows inside it are not centered on
    // each other. Pinning the width here is what lets the heading and the hint
    // share the grid's left edge instead of widening the block and pushing the
    // tiles off-centre.
    readonly property int gridWidth:
      root.pickerColumns * tileSize + (root.pickerColumns - 1) * gap

    Rectangle {
      anchors.fill: parent
      // How much of the desktop shows through: turn the 0.85 down to reveal
      // more of it. Stated here rather than taken from Color.menu.scrim,
      // which a theme may set to fully transparent -- and an undimmed picker
      // leaves its own heading and hint unreadable on whatever is behind.
      //
      // The alpha is a literal on purpose. Bound to a property of this window
      // it evaluated as 0 before the initializer ran, and an alpha of 0 is a
      // scrim that silently is not there.
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.85)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.closePicker()
    }

    Item {
      id: pickerKeys
      anchors.fill: parent
      focus: true

      // Handled explicitly rather than through PanelKeyCatcher: that one binds
      // Space to activate and `x` to delete, and a stray Space that fires an
      // LLM call is a misfire this surface cannot afford.
      // In compose mode every key belongs to the text box, including the
      // letters that steer the grid -- otherwise typing "hallo" walks the
      // cursor instead of writing.
      Keys.onEscapePressed: root.closePicker()
      Keys.onLeftPressed: root.movePicker(-1, 0)
      Keys.onRightPressed: root.movePicker(1, 0)
      Keys.onUpPressed: root.movePicker(0, -1)
      Keys.onDownPressed: root.movePicker(0, 1)
      Keys.onTabPressed: root.movePicker(1, 0)
      Keys.onBacktabPressed: root.movePicker(-1, 0)
      Keys.onReturnPressed: root.activatePicker()
      Keys.onEnterPressed: root.activatePicker()
      Keys.onPressed: function(event) {
        // The digits on the tiles are the point of the digits on the tiles.
        if (event.text >= "1" && event.text <= "9") {
          var wanted = event.text.charCodeAt(0) - 49
          if (wanted < root.pickerCount) {
            root.pickerIndex = wanted
            root.activatePicker()
          }
          event.accepted = true
        } else if ("hjkl".indexOf(event.text) >= 0 && event.text !== "") {
          root.movePicker(event.text === "l" ? 1 : event.text === "h" ? -1 : 0,
                          event.text === "j" ? 1 : event.text === "k" ? -1 : 0)
          event.accepted = true
        }
      }

      Column {
        anchors.centerIn: parent
        width: picker.gridWidth
        spacing: Style.space(16)
        visible: root.pickerMode === "grid"

        Text {
          width: parent.width
          text: "Correct with"
          color: Color.menu.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        // Rows of tiles rather than a GridView, for the index-to-cell mapping
        // Model.moveIndex navigates: n is a dozen at most, so there is nothing
        // to virtualise. Rows start at x = 0, so a short last row sits under
        // the first columns rather than floating between them.
        Column {
          spacing: picker.gap

          Repeater {
            model: Math.ceil(root.pickerCount / root.pickerColumns)

            Row {
              id: tileRow
              required property int index
              spacing: picker.gap

              Repeater {
                model: Math.min(root.pickerColumns,
                                root.pickerCount - tileRow.index * root.pickerColumns)

                BorderSurface {
                  id: tile
                  required property int index

                  readonly property int slot: tileRow.index * root.pickerColumns + tile.index
                  readonly property var entry: root.profiles[tile.slot] || null
                  readonly property bool chosen: tile.slot === root.pickerIndex
                  // The last tile is not a profile: it is never in
                  // profiles.json, never in the Prompts tab, and the
                  // normalizer never sees it. It is made up here, at render
                  // time, and it opens a text box instead of running.
                  readonly property bool custom: tile.slot === root.profiles.length

                  width: picker.tileSize
                  height: picker.tileSize
                  radius: Style.cornerRadius
                  // Opaque, like the first-party menu cards. The usual panel
                  // fills are a 4% tint and menu.selectedBackground an 8% one,
                  // which over a half-transparent scrim leaves the tile as
                  // wallpaper with text on it -- unreadable over anything busy.
                  color: Color.menu.background
                  // Border.controlSpec("selected", ...) is not usable here:
                  // selected-border-width defaults to 0, so the chosen tile
                  // would carry no frame at all and the only cue left would be
                  // the title colour. An explicit accent ring, the way the
                  // overview marks its selection.
                  borderSpec: tile.chosen
                    ? Border.flat(Color.accent, Style.space(2))
                    : Border.flat(Util.alpha(Color.menu.text, 0.18), Style.spacing.hairline)

                  // The selection tint is composited onto the solid card
                  // rather than replacing it, so it stays a highlight instead
                  // of punching a hole back through to the desktop.
                  Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: Color.menu.selectedBackground
                    opacity: tile.chosen ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                  }

                  // The number is not decoration: it names the key that picks
                  // this tile outright.
                  Text {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: Style.space(10)
                    visible: tile.slot < 9
                    text: String(tile.slot + 1)
                    color: tile.chosen ? Color.menu.selectedText : Util.alpha(Color.menu.text, 0.55)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  // Which prompt the keybind would have used on its own. Never
                  // the custom tile: it is not something you can default to.
                  Text {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(10)
                    visible: tile.entry !== null && tile.entry.name === root.profile
                    text: "●"
                    color: tile.chosen ? Color.menu.selectedText : root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Column {
                    anchors.centerIn: parent
                    width: parent.width - Style.space(20)
                    spacing: Style.space(4)

                    // One slot for both: the composer's glyph and whatever
                    // icon a prompt was given. A prompt without one simply
                    // shows its title, the way every tile looked before.
                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      visible: tile.custom || (tile.entry !== null && Model.hasIcon(tile.entry))
                      text: tile.custom ? "✎" : (tile.entry ? tile.entry.icon : "")
                      color: tile.chosen ? Color.menu.selectedText : Color.menu.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.display
                    }

                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      text: tile.custom ? "Custom…"
                        : (tile.entry ? (tile.entry.title || tile.entry.name) : "")
                      color: tile.chosen ? Color.menu.selectedText : Color.menu.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.heading
                      wrapMode: Text.WordWrap
                      maximumLineCount: 3
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      visible: tile.custom
                      text: "Type an instruction"
                      color: Util.alpha(Color.menu.text, 0.55)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    // Movement, not mere presence. The overlay maps under
                    // wherever the pointer happens to be resting, and onEntered
                    // would fire there immediately -- throwing away the
                    // preselected default before the user has touched anything.
                    onPositionChanged: root.pickerIndex = tile.slot
                    onClicked: root.activatePicker()
                  }
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "↑↓←→ choose · 1-9 pick · Enter correct · Esc cancel"
          // Sits on the scrim, not on a card, so it takes its colour from the
          // menu text rather than the panel's dim -- which is tuned for a
          // solid panel background and disappears here.
          color: Util.alpha(Color.menu.text, 0.65)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // Compose: the grid is replaced, not covered, and the block keeps the
      // grid's width so it does not jump when the mode changes.
      Column {
        anchors.centerIn: parent
        width: picker.gridWidth
        spacing: Style.space(16)
        visible: root.pickerMode === "compose"

        Text {
          width: parent.width
          text: "Custom prompt"
          color: Color.menu.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        BorderSurface {
          width: parent.width
          height: Style.space(120)
          radius: Style.cornerRadius
          color: Color.menu.background
          borderSpec: Border.flat(Color.accent, Style.space(2))

          Flickable {
            anchors.fill: parent
            anchors.margins: Style.spacing.controlPaddingY
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            TextArea.flickable: TextArea {
              id: instructionArea
              wrapMode: TextArea.Wrap
              placeholderText: "e.g. shorten this to one sentence"
              placeholderTextColor: Util.alpha(Color.menu.text, 0.45)
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectionColor: Style.selectionFillFor(Color.menu.text, Color.accent, Color.urgent)
              selectedTextColor: Color.menu.text
              background: null

              // Enter runs it; Shift+Enter is how you get a second line. A
              // text box whose Enter inserts a newline would make the common
              // case -- one short instruction -- cost a reach for the mouse.
              Keys.onReturnPressed: function(event) {
                if (event.modifiers & Qt.ShiftModifier) {
                  event.accepted = false
                } else {
                  root.runCustom(instructionArea.text)
                  event.accepted = true
                }
              }
              Keys.onEnterPressed: function(event) {
                if (event.modifiers & Qt.ShiftModifier) {
                  event.accepted = false
                } else {
                  root.runCustom(instructionArea.text)
                  event.accepted = true
                }
              }
              // Escape steps back to the grid; a second one closes the picker.
              Keys.onEscapePressed: function(event) {
                root.closeCompose()
                event.accepted = true
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "Enter correct · Shift+Enter new line · Esc back"
          color: Util.alpha(Color.menu.text, 0.65)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
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
      // Every key typed into the prompt editor would otherwise run this
      // panel's shortcuts first: Keys.priority is BeforeItem, so a `c` in the
      // middle of a sentence would start a correction. This is what `blocked`
      // is for.
      blocked: titleField.activeFocus || systemArea.activeFocus || root.iconPickerOpen
      // A dialog on top owns the keyboard until it is answered.
      onCloseRequested: {
        if (root.openDialog) root.dialogCancel()
        else root.close()
      }
      onReturnRequested: if (root.openDialog) root.dialogActivate()
      // `x` is what PanelKeyCatcher calls deletion everywhere else in the
      // shell; on the Prompts tab it asks the same question the button does.
      onDeleteRequested: {
        if (!root.openDialog && root.tabIndex === 2 && root.draftProfile !== null
            && root.profiles.length > 1)
          confirmDelete.opened = true
      }
      onTabRequested: function(direction) {
        if (root.openDialog) root.dialogToggle()
        else root.switchPanel(direction)
      }
      // PanelKeyCatcher swallows lowercase h/j/k/l as vim movement and returns
      // before textKey ever fires, so the `h` shortcut below could never run
      // on its own -- only Shift+H reached it. Left/right moving between the
      // tabs is what the keys mean in a three-tab panel, and it makes plain
      // `h` work the way the README always claimed.
      onMoveRequested: function(dx, dy) {
        if (root.openDialog) {
          if (dx !== 0) root.dialogToggle()
          return
        }
        if (dx !== 0) root.tabIndex = Math.max(0, Math.min(2, root.tabIndex + dx))
        // Up and down walk the prompt list, which is otherwise reachable only
        // with the mouse -- and the delete shortcut needs something selected.
        else if (dy !== 0 && root.tabIndex === 2) root.stepPrompt(dy)
      }
      onTextKey: function(t) {
        if (root.openDialog) return
        if (t === "c" || t === "C") root.correct()
        else if (t === "H") root.tabIndex = 0
        else if (t === "s" || t === "S") root.tabIndex = 1
        else if (t === "p" || t === "P") root.tabIndex = 2
        else if ((t === "n" || t === "N") && root.tabIndex === 2) root.newPrompt()
        // The rest of the panel is keyboard-driven; the icon picker would be
        // the one corner reachable only by mouse without this.
        else if ((t === "i" || t === "I") && root.tabIndex === 2 && root.draftName !== "")
          root.openIconPicker()
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
            options: [{ value: "history", label: "History" },
                      { value: "prompts", label: "Prompts" },
                      { value: "settings", label: "Settings" }]
            value: root.tabValues[root.tabIndex]
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(v) { root.tabIndex = Math.max(0, root.tabValues.indexOf(v)) }
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
              label: "Default prompt"
              value: root.profile
              // {value, label} pairs: the setting stores the name, the user
              // reads the title. Dropdown handles either shape.
              options: root.profileOptions
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

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap

              PanelSectionHeader {
                text: "EFFORT"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              TextField {
                width: parent.width
                text: root.effort
                foreground: root.foreground
                onEditingFinished: if (text !== root.effort) root.updateSetting("effort", text)
              }

              Text {
                width: parent.width
                text: "Empty lets the backend decide. On a thinking model served by ollama, "
                      + "\"none\" turns the deliberation off — about six times faster at the "
                      + "same quality, because proofreading has nothing to deliberate about."
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
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: doctorProc.running = true
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

          // ------------------------------------------------------ prompts

          Column {
            visible: root.tabIndex === 2
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "Prompts"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.profiles

              CursorSurface {
                id: promptRow
                required property var modelData

                width: parent.width
                implicitHeight: promptText.implicitHeight + Style.spacing.rowPaddingX
                // `current` is the kit's name for "this is the selected row";
                // CursorSurface carries no click handling of its own, so the
                // MouseArea below is the row's, exactly as HistoryRow does it.
                current: promptRow.modelData.name === root.draftName
                foreground: root.foreground

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectPrompt(promptRow.modelData.name)
                }

                Column {
                  id: promptText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(2)

                  Row {
                    spacing: Style.space(6)

                    Text {
                      visible: Model.hasIcon(promptRow.modelData)
                      text: promptRow.modelData.icon
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      text: promptRow.modelData.title || promptRow.modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      visible: promptRow.modelData.name === root.profile
                      text: "default"
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    width: promptText.width
                    text: Model.summarize(promptRow.modelData.system, 52)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              // bordered, because Ui.Button defaults to bare text on a
              // transparent ground: without a frame these read as labels
              // rather than as the things that add and remove a prompt.
              Button {
                text: "New"
                iconText: "󰐕"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.newPrompt()
              }

              Button {
                text: "Default"
                iconText: "󰓎"
                bordered: true
                // Button inherits enabled down to its MouseArea, so this stops
                // the click; the opacity is what makes that visible.
                enabled: root.draftName !== "" && root.draftName !== root.profile && !root.draftIsNew
                opacity: enabled ? 1.0 : 0.45
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.updateSetting("profile", root.draftName)
              }

              Button {
                // The CLI refuses an empty profiles.json anyway; disabling the
                // button is how that refusal stays out of the user's way.
                text: "Delete"
                iconText: "󰩹"
                bordered: true
                enabled: root.profiles.length > 1 && root.draftProfile !== null
                opacity: enabled ? 1.0 : 0.45
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: confirmDelete.opened = true
              }
            }

            PanelSeparator { foreground: root.foreground }

            Text {
              visible: root.draftName === ""
              width: parent.width
              text: "Pick a prompt to edit it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            PanelSectionHeader {
              visible: root.draftName !== ""
              width: parent.width
              text: "Title"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: titleField
              visible: root.draftName !== ""
              width: parent.width
              placeholderText: "What the tile says"
              foreground: root.foreground
              onTextEdited: root.draftTitle = text
              // Escape leaves the field rather than dying here: with the key
              // catcher blocked it would otherwise reach a field that ignores
              // it, and the panel could no longer be closed from the keyboard.
              Keys.onEscapePressed: function(event) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            PanelSectionHeader {
              visible: root.draftName !== ""
              width: parent.width
              text: "Icon"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // The picker itself is a modal over the whole panel: ten thousand
            // glyphs do not fit under a label, and searching them needs a
            // field of its own. This is only the current value and the way in.
            Row {
              visible: root.draftName !== ""
              width: parent.width
              spacing: Style.space(8)

              CursorSurface {
                width: Style.space(30)
                height: Style.space(30)
                current: root.draftIcon !== ""
                foreground: root.foreground

                Text {
                  anchors.centerIn: parent
                  text: root.draftIcon === "" ? "—" : root.draftIcon
                  color: root.draftIcon === "" ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openIconPicker()
                }
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                text: "Choose…"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.openIconPicker()
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                text: "Clear"
                bordered: true
                enabled: root.draftIcon !== ""
                opacity: enabled ? 1.0 : 0.45
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.draftIcon = ""
              }
            }

            PanelSectionHeader {
              visible: root.draftName !== ""
              width: parent.width
              text: "Prompt"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // qs.Ui has no multi-line field, so this is a raw TextArea wearing
            // the kit's clothes -- same fill, border and insets as Ui/TextField.
            Flickable {
              visible: root.draftName !== ""
              width: parent.width
              height: Style.space(150)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              TextArea.flickable: TextArea {
                id: systemArea
                wrapMode: TextArea.Wrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                selectionColor: Style.selectionFillFor(root.foreground, root.accent, root.urgent)
                selectedTextColor: root.foreground
                padding: Style.spacing.controlPaddingY
                leftPadding: Style.spacing.controlPaddingX
                rightPadding: Style.spacing.controlPaddingX
                onTextChanged: root.draftSystem = text

                background: BorderSurface {
                  radius: Style.cornerRadius
                  color: Style.controlFill(systemArea.activeFocus, systemArea.hovered,
                                           root.foreground, root.accent)
                  borderSpec: Border.controlSpec(systemArea.activeFocus ? "focus" : "normal",
                                                 root.foreground, root.accent, root.urgent)
                }

                Keys.onEscapePressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            // A prompt without these two rules still saves -- the file is the
            // user's -- but the selection stops being quarantined as data, and
            // that is worth saying out loud rather than discovering later.
            Text {
              visible: root.draftName !== "" && !root.draftGuarded
              width: parent.width
              text: "Without <text> and \"nothing else\", this prompt drops the injection guard."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.promptsError !== ""
              width: parent.width
              text: root.promptsError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              visible: root.draftName !== ""
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Save"
                iconText: "󰆓"
                bordered: true
                enabled: root.promptsDirty
                opacity: enabled ? 1.0 : 0.45
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.savePrompts()
              }

              Button {
                text: "Revert"
                iconText: "󰕌"
                bordered: true
                enabled: root.promptsDirty && !root.draftIsNew
                opacity: enabled ? 1.0 : 0.45
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.selectPrompt(root.draftName)
              }

              Text {
                visible: root.promptsDirty
                anchors.verticalCenter: parent.verticalCenter
                text: "Unsaved"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            PanelSeparator { foreground: root.foreground }

            Button {
              text: "Open profiles.json"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: editProc.running = true
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

    // A modal over the panel, the way ConfirmDialog is one: the search field
    // wants the keyboard, and a grid of ten thousand glyphs wants the room.
    Rectangle {
      id: iconPicker
      anchors.fill: parent
      visible: root.iconPickerOpen
      color: Color.popups.background
      radius: Style.cornerRadius

      // Swallows clicks so they cannot reach the prompt list behind it.
      MouseArea { anchors.fill: parent }

      Column {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.space(8)

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Icon"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.iconMatches.length + (root.iconMatches.length === 400 ? "+" : "")
              + " of " + root.icons.length
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        TextField {
          id: iconSearch
          width: parent.width
          placeholderText: "Search · pencil, mail, code…"
          foreground: root.foreground
          onTextEdited: { root.iconQuery = text; root.iconIndex = 0 }

          // The field keeps the keyboard so typing filters, and the arrows
          // are forwarded to the grid rather than walking the caret.
          Keys.onUpPressed: root.moveIconCursor(0, -1)
          Keys.onDownPressed: root.moveIconCursor(0, 1)
          Keys.onLeftPressed: function(event) {
            if (iconSearch.text === "") { root.moveIconCursor(-1, 0); event.accepted = true }
            else event.accepted = false
          }
          Keys.onRightPressed: function(event) {
            if (iconSearch.text === "") { root.moveIconCursor(1, 0); event.accepted = true }
            else event.accepted = false
          }
          Keys.onReturnPressed: function(event) {
            var hit = root.iconMatches[root.iconIndex]
            if (hit) root.pickIcon(hit[0])
            event.accepted = true
          }
          Keys.onEscapePressed: function(event) {
            root.closeIconPicker()
            event.accepted = true
          }
        }

        // The name of whatever the cursor is on, so a glyph nobody recognises
        // can still be identified before it is chosen.
        Text {
          width: parent.width
          text: root.iconMatches[root.iconIndex]
            ? root.iconMatches[root.iconIndex][1] : "no match"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        GridView {
          id: iconGrid
          width: parent.width
          height: parent.height - y
          clip: true
          cellWidth: Math.floor(width / root.iconColumns)
          cellHeight: cellWidth
          model: root.iconMatches
          currentIndex: root.iconIndex
          // Keeps the keyboard cursor on screen while it walks the grid.
          onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: CursorSurface {
            id: iconCell
            required property var modelData
            required property int index

            width: iconGrid.cellWidth - Style.space(2)
            height: iconGrid.cellHeight - Style.space(2)
            current: iconCell.index === root.iconIndex
            foreground: root.foreground

            Text {
              anchors.centerIn: parent
              text: iconCell.modelData ? iconCell.modelData[0] : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: root.iconIndex = iconCell.index
              onClicked: root.pickIcon(iconCell.modelData[0])
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: confirmDelete
      anchors.fill: parent
      message: "Delete the prompt “" + root.draftTitle + "”?"
      confirmText: "Delete"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onConfirmed: { root.deletePrompt(root.draftName); opened = false }
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
