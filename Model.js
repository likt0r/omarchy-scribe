// Pure logic for the Scribe widget and its panel.
//
// Everything here is Qt-free so node can test it (tests/model-test.js). The
// QML owns rendering, process spawning and file IO; this file owns the
// decisions -- which state comes next, which adapter wins, what a history
// entry looks like, and which sentence an exit code turns into.

// ---- Widget states.
//
// "done" is a transient state the widget holds briefly so a fast correction
// still registers as having happened; "error" is sticky because a failure the
// user never saw is a failure they will hit again.
var STATE_IDLE = "idle"
var STATE_WORKING = "working"
var STATE_DONE = "done"
var STATE_ERROR = "error"

var DONE_HOLD_MS = 1500

// Exit codes the `scribe` CLI uses. The widget never parses stderr to decide
// what went wrong -- the code decides, stderr only supplies the detail line.
var EXIT_OK = 0
var EXIT_USAGE = 1
var EXIT_CONFIG = 2
var EXIT_UPSTREAM = 3
var EXIT_NO_SELECTION = 4
var EXIT_TIMEOUT = 5

// A correction is a request/response cycle, so the state machine is small.
// It is written out rather than inferred because "start while already
// working" and "finish after a cancel" are the two transitions that decide
// whether a stuck spinner is possible, and both deserve to be pinned by a
// test.
function nextState(current, event) {
  switch (event) {
    case "start":
      // Starting from any state is legal -- a new correction supersedes a
      // held tick or a stale error. Suppressing a second keypress *while*
      // working is the caller's job, not the machine's: two adapters racing
      // to wl-copy would leave the clipboard holding whichever finished
      // last, which need not be the one the user waited for.
      return STATE_WORKING
    case "succeed":
      return current === STATE_WORKING ? STATE_DONE : current
    case "fail":
      return current === STATE_WORKING ? STATE_ERROR : current
    case "settle":
      // The done-hold timer firing. Only "done" decays; "error" waits to be
      // acknowledged.
      return current === STATE_DONE ? STATE_IDLE : current
    case "acknowledge":
      // Opening the panel clears a sticky error -- the user has now seen it.
      return current === STATE_ERROR ? STATE_IDLE : current
    case "cancel":
      return current === STATE_WORKING ? STATE_IDLE : current
    default:
      return current
  }
}

function isBusy(state) {
  return state === STATE_WORKING
}

// ---- Adapter discovery.
//
// The user directory wins so a hand-written adapter can shadow a shipped one
// without touching the repo -- the same precedence the calendar plugin's
// exporters use.
function adapterCandidates(name, userDir, pluginDir) {
  var safe = adapterName(name)
  if (safe === "") return []
  var out = []
  if (userDir) out.push(joinPath(userDir, safe))
  if (pluginDir) out.push(joinPath(pluginDir, safe))
  return out
}

// A backend name comes out of shell.json, which is a file the user edits by
// hand. Anything with a slash or a leading dot would let a typo reach outside
// the two backend directories, so the name is restricted rather than escaped.
function adapterName(name) {
  var s = String(name === undefined || name === null ? "" : name).trim()
  if (s === "" || s === "." || s === "..") return ""
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(s)) return ""
  return s
}

function joinPath(dir, name) {
  var d = String(dir)
  return d.charAt(d.length - 1) === "/" ? d + name : d + "/" + name
}

// Merge the shipped adapter list with whatever the user dropped in, so the
// settings dropdown offers both without listing a shadowed name twice.
function adapterChoices(shipped, userSupplied) {
  var seen = {}
  var out = []
  var all = (userSupplied || []).concat(shipped || [])
  for (var i = 0; i < all.length; i++) {
    var n = adapterName(all[i])
    if (n === "" || seen[n]) continue
    seen[n] = true
    out.push(n)
  }
  out.sort()
  return out
}

// ---- Prompt profiles.
//
// The profiles file is user-owned and hand-edited, so every read has to cope
// with it being absent, truncated mid-save, or missing the profile the
// settings still point at.
function normalizeProfiles(raw) {
  var out = []
  var list = raw && raw.profiles
  if (!Array.isArray(list)) return out
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!p || typeof p !== "object") continue
    var name = String(p.name === undefined ? "" : p.name).trim()
    var system = String(p.system === undefined ? "" : p.system).trim()
    if (name === "" || system === "" || seen[name]) continue
    seen[name] = true
    // `name` is the identity -- what --profile takes and what shell.json
    // stores -- and `title` is only the label, so a title the user renamed or
    // never set falls back to the name instead of showing an empty tile. Kept
    // in step with normalize_profiles() in `scribe`.
    var title = String(p.title === undefined ? "" : p.title).trim()
    // The icon is optional and has no fallback: a profile without one shows
    // its title alone, which is what every profile looked like before icons.
    var icon = String(p.icon === undefined ? "" : p.icon).trim()
    out.push({ name: name, title: title === "" ? name : title, icon: icon, system: system })
  }
  return out
}

// The label for a profile the picker and the dropdown show. Takes the object
// or the bare name, so a caller holding only what shell.json stored can still
// ask for a title.
function profileTitle(profiles, wanted) {
  var profile = typeof wanted === "object" && wanted !== null
    ? wanted : resolveProfile(profiles, wanted)
  if (!profile) return String(wanted || "")
  return profile.title || profile.name
}

// A name for a newly created profile, derived from its title. `name` is the
// identity the settings and the history store, so it is generated once and
// then frozen -- renaming the title later must not orphan either. Suffixed
// until it is unique, because a duplicate name is dropped by normalize.
function profileName(title, taken) {
  var base = String(title || "").trim().toLowerCase()
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  if (base === "") base = "prompt"
  var used = {}
  var list = taken || []
  for (var i = 0; i < list.length; i++) {
    used[typeof list[i] === "object" && list[i] !== null ? list[i].name : list[i]] = true
  }
  if (!used[base]) return base
  for (var n = 2; ; n++) {
    if (!used[base + "-" + n]) return base + "-" + n
  }
}

// ---- The picker grid.
//
// The tiles are laid out as square as the count allows, so eight prompts are
// 3x3 with a gap rather than 8x1. A ragged last row is left as it falls.
function gridColumns(count) {
  return count > 0 ? Math.ceil(Math.sqrt(count)) : 1
}

// Cursor movement, clamped rather than wrapped. Wrapping in a grid whose last
// row is ragged puts the cursor somewhere the eye did not follow; clamping
// means a held arrow key stops at the edge, which is what a grid of a dozen
// tiles wants. Moving down out of a short last column lands on the last tile
// rather than nowhere.
function moveIndex(index, dx, dy, count, columns) {
  if (count <= 0) return 0
  var cols = columns > 0 ? columns : gridColumns(count)
  var current = Math.min(Math.max(index, 0), count - 1)
  if (dx) {
    var row = Math.floor(current / cols)
    var next = current + dx
    if (next < row * cols || next > Math.min(row * cols + cols - 1, count - 1)) return current
    return next
  }
  if (dy) {
    var target = current + dy * cols
    if (target < 0) return current
    if (target < count) return target
    // Past the end going down. Only a tile standing above the ragged gap
    // slides to the last tile; one already in the bottom row stays put, so a
    // held Down key does not creep sideways along it.
    var inLastRow = Math.floor(current / cols) === Math.floor((count - 1) / cols)
    return dy > 0 && !inLastRow ? count - 1 : current
  }
  return current
}

// Falls through to the first profile rather than erroring: a correction that
// runs with the wrong prompt is recoverable, one that refuses to run because
// a profile was renamed is just an obstacle.
function resolveProfile(profiles, wanted) {
  var list = profiles || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].name === wanted) return list[i]
  }
  return list.length > 0 ? list[0] : null
}

// ---- Icons.
//
// Nerd Font glyphs, which is what the shell paints every other icon with --
// the family is whatever fontconfig resolves `monospace` to, so an icon is an
// ordinary character. The pickable list is generated into icons.json by
// tools/generate-icons.py; see filterIcons below.

// A profile with no icon is normal, and the tile just shows its title.
function hasIcon(profile) {
  return !!(profile && typeof profile.icon === "string" && profile.icon.length > 0)
}
// Search over the generated icons.json: entries are [glyph, name] pairs and
// the names come from the font itself ("md-pencil", "fa-scissors"), which is
// what makes ten thousand glyphs findable at all.
//
// Ranked rather than merely filtered, because "pencil" matches 25 names and
// the one actually called pencil has to be first. The cap exists because the
// grid is rebuilt on every keystroke.
function filterIcons(icons, query, limit) {
  var list = icons || []
  var max = limit > 0 ? limit : 300
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return list.slice(0, max)

  var exact = [], starts = [], word = [], rest = []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || entry.length < 2) continue
    var name = String(entry[1]).toLowerCase()
    var at = name.indexOf(q)
    if (at < 0) continue
    // The family prefix is not what anyone types, so "pencil" has to count as
    // the start of "md-pencil" too.
    var bare = name.indexOf("-") >= 0 ? name.slice(name.indexOf("-") + 1) : name
    if (name === q || bare === q) exact.push(entry)
    else if (at === 0 || bare.indexOf(q) === 0) starts.push(entry)
    else if (name.charAt(at - 1) === "_" || name.charAt(at - 1) === "-") word.push(entry)
    else rest.push(entry)
    if (exact.length >= max) break
  }
  return exact.concat(starts, word, rest).slice(0, max)
}

// ---- History.

// `historyStoreText: false` has to mean nothing quotable reaches the disk,
// while the panel still shows that a run happened and what it cost. Lengths
// survive; the text does not.
function historyEntry(run, opts) {
  var o = opts || {}
  var original = String(run.original === undefined ? "" : run.original)
  var corrected = String(run.corrected === undefined ? "" : run.corrected)
  var entry = {
    ts: run.ts,
    profile: run.profile || "",
    backend: run.backend || "",
    model: run.model || "",
    ms: typeof run.ms === "number" ? run.ms : null,
    originalLength: original.length,
    correctedLength: corrected.length,
    changed: original !== corrected
  }
  if (run.usage) entry.usage = run.usage
  if (o.storeText !== false) {
    entry.original = original
    entry.corrected = corrected
    // A one-off instruction is text the user wrote, so it keeps the company
    // of the other text and goes with it under metadata-only. Kept in step
    // with record_history() in `scribe`.
    if (run.instruction) entry.instruction = String(run.instruction)
  }
  return entry
}

function hasText(entry) {
  return !!entry && typeof entry.corrected === "string"
}

// Newest first, so the panel renders the list as-is and a trim drops the tail.
function appendHistory(entries, entry, limit) {
  var list = (entries || []).slice()
  list.unshift(entry)
  return trimHistory(list, limit)
}

function trimHistory(entries, limit) {
  var list = entries || []
  var n = typeof limit === "number" && limit >= 0 ? Math.floor(limit) : 50
  return list.length > n ? list.slice(0, n) : list.slice()
}

// One line for the history list. Collapses the whitespace a marked paragraph
// carries so multi-line selections do not each take three rows.
function summarize(text, maxLength) {
  var max = typeof maxLength === "number" && maxLength > 1 ? Math.floor(maxLength) : 60
  var s = String(text === undefined || text === null ? "" : text)
    .replace(/\s+/g, " ")
    .trim()
  if (s.length <= max) return s

  var cut = s.slice(0, max - 1)
  // Drop the trailing partial word only when the cut actually landed inside
  // one. Slicing exactly on a word boundary is already the tidiest possible
  // break, and trimming there would throw a whole word away for nothing.
  if (!/\s/.test(s.charAt(max - 1))) {
    var tidied = cut.replace(/\s+\S*$/, "")
    if (tidied !== "") cut = tidied
  }
  return cut + "…"
}

function formatDuration(ms) {
  if (typeof ms !== "number" || !isFinite(ms) || ms < 0) return ""
  if (ms < 1000) return Math.round(ms) + " ms"
  return (ms / 1000).toFixed(1) + " s"
}

function formatUsage(usage) {
  if (!usage) return ""
  var i = usage.input_tokens, o = usage.output_tokens
  if (typeof i !== "number" && typeof o !== "number") return ""
  return (typeof i === "number" ? i : "?") + " in / " +
         (typeof o === "number" ? o : "?") + " out"
}

// ---- Errors.
//
// The exit code carries the category and the widget phrases it; stderr adds
// the specifics the CLI knows and the widget cannot guess (which key is
// missing, what the API said). Both are shown -- the sentence tells the user
// what kind of problem it is, the detail tells them which one.
function errorMessage(exitCode, stderr) {
  var detail = String(stderr === undefined || stderr === null ? "" : stderr).trim()
  detail = detail.split("\n").filter(function (l) { return l.trim() !== "" }).pop() || ""
  var head
  switch (exitCode) {
    case EXIT_NO_SELECTION:
      head = "Nothing selected."
      break
    case EXIT_CONFIG:
      head = "Backend is not configured."
      break
    case EXIT_UPSTREAM:
      head = "The model could not be reached."
      break
    case EXIT_TIMEOUT:
      head = "Timed out."
      break
    case EXIT_USAGE:
      head = "Scribe was called incorrectly."
      break
    default:
      head = "Correction failed."
  }
  return detail === "" ? head : head + " " + detail
}

// A short form for the bar tooltip, where the full stderr line does not fit.
function errorHeadline(exitCode) {
  return errorMessage(exitCode, "")
}

if (typeof module !== "undefined") {
  module.exports = {
    STATE_IDLE: STATE_IDLE,
    STATE_WORKING: STATE_WORKING,
    STATE_DONE: STATE_DONE,
    STATE_ERROR: STATE_ERROR,
    DONE_HOLD_MS: DONE_HOLD_MS,
    EXIT_OK: EXIT_OK,
    EXIT_USAGE: EXIT_USAGE,
    EXIT_CONFIG: EXIT_CONFIG,
    EXIT_UPSTREAM: EXIT_UPSTREAM,
    EXIT_NO_SELECTION: EXIT_NO_SELECTION,
    EXIT_TIMEOUT: EXIT_TIMEOUT,
    nextState: nextState,
    isBusy: isBusy,
    adapterCandidates: adapterCandidates,
    adapterName: adapterName,
    adapterChoices: adapterChoices,
    normalizeProfiles: normalizeProfiles,
    resolveProfile: resolveProfile,
    profileTitle: profileTitle,
    profileName: profileName,
    gridColumns: gridColumns,
    hasIcon: hasIcon,
    filterIcons: filterIcons,
    moveIndex: moveIndex,
    historyEntry: historyEntry,
    hasText: hasText,
    appendHistory: appendHistory,
    trimHistory: trimHistory,
    summarize: summarize,
    formatDuration: formatDuration,
    formatUsage: formatUsage,
    errorMessage: errorMessage,
    errorHeadline: errorHeadline
  }
}
