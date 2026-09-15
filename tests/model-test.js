// Tests for Model.js -- the decisions the widget makes, with no Qt involved.
//
// The state machine gets the most attention because its failure mode is a
// spinner that never stops, which the user can only clear by restarting the
// shell. Every transition is pinned, including the ones that should do
// nothing.
//
// Run: node tests/model-test.js

const path = require('path')
const Model = require(path.join(__dirname, '..', 'Model.js'))

const failures = []
let checks = 0

function check(label, got, want) {
  checks++
  const g = JSON.stringify(got), w = JSON.stringify(want)
  if (g !== w) failures.push(`${label}\n     got:  ${g}\n     want: ${w}`)
}

// ---------------------------------------------------------------- nextState

const IDLE = Model.STATE_IDLE
const WORKING = Model.STATE_WORKING
const DONE = Model.STATE_DONE
const ERROR = Model.STATE_ERROR

check('start from idle works', Model.nextState(IDLE, 'start'), WORKING)
check('start from error works', Model.nextState(ERROR, 'start'), WORKING)
check('start from done works', Model.nextState(DONE, 'start'), WORKING)
check('start while working stays working', Model.nextState(WORKING, 'start'), WORKING)

check('succeed from working is done', Model.nextState(WORKING, 'succeed'), DONE)
check('fail from working is error', Model.nextState(WORKING, 'fail'), ERROR)

// A result arriving after a cancel must not resurrect the spinner or paint a
// tick for a run the user already abandoned.
check('succeed after cancel is ignored', Model.nextState(IDLE, 'succeed'), IDLE)
check('fail after cancel is ignored', Model.nextState(IDLE, 'fail'), IDLE)

check('settle clears done', Model.nextState(DONE, 'settle'), IDLE)
check('settle leaves error alone', Model.nextState(ERROR, 'settle'), ERROR)
check('settle on idle is a no-op', Model.nextState(IDLE, 'settle'), IDLE)
// The done-hold timer must never be able to cut a fresh run short.
check('settle does not interrupt working', Model.nextState(WORKING, 'settle'), WORKING)

check('acknowledge clears error', Model.nextState(ERROR, 'acknowledge'), IDLE)
check('acknowledge leaves working alone', Model.nextState(WORKING, 'acknowledge'), WORKING)
// A broken config is not the outcome of a run, so it must reach the error
// state from anywhere -- including idle, which is where it is usually found.
check('misconfigure errors from idle', Model.nextState(IDLE, 'misconfigure'), ERROR)
check('misconfigure errors from working', Model.nextState(WORKING, 'misconfigure'), ERROR)
check('misconfigure errors from done', Model.nextState(DONE, 'misconfigure'), ERROR)

check('a plain error is the last stderr line',
  Model.plainError("warning: x\nprofiles.json is not valid JSON\n"), 'profiles.json is not valid JSON')
check('a plain error of nothing is empty', Model.plainError(''), '')
check('a plain error copes with null', Model.plainError(null), '')

check('cancel stops working', Model.nextState(WORKING, 'cancel'), IDLE)
check('cancel on idle is a no-op', Model.nextState(IDLE, 'cancel'), IDLE)
check('unknown event changes nothing', Model.nextState(WORKING, 'wat'), WORKING)

check('isBusy only for working', [IDLE, WORKING, DONE, ERROR].map(Model.isBusy),
  [false, true, false, false])

// ------------------------------------------------------------ adapter names

check('plain name passes', Model.adapterName('anthropic'), 'anthropic')
check('dashes and dots pass', Model.adapterName('claude-cli.v2'), 'claude-cli.v2')
check('surrounding space is trimmed', Model.adapterName('  openai '), 'openai')
// The name comes from a hand-edited shell.json, so a path in it is rejected
// rather than escaped -- there is no legitimate reason for one.
check('a path is rejected', Model.adapterName('../../bin/sh'), '')
check('a slash is rejected', Model.adapterName('sub/dir'), '')
check('a leading dot is rejected', Model.adapterName('.hidden'), '')
check('empty is rejected', Model.adapterName(''), '')
check('undefined is rejected', Model.adapterName(undefined), '')

check('candidates prefer the user directory',
  Model.adapterCandidates('anthropic', '/home/u/.config/omarchy/scribe/backends', '/opt/scribe/backends'),
  ['/home/u/.config/omarchy/scribe/backends/anthropic', '/opt/scribe/backends/anthropic'])
check('a trailing slash does not double up',
  Model.adapterCandidates('x', '/a/', '/b'), ['/a/x', '/b/x'])
check('a rejected name yields no candidates',
  Model.adapterCandidates('../sh', '/a', '/b'), [])

check('choices merge and dedupe',
  Model.adapterChoices(['anthropic', 'openai'], ['anthropic', 'mine']),
  ['anthropic', 'mine', 'openai'])
check('choices drop invalid names',
  Model.adapterChoices(['ok'], ['../bad', '']), ['ok'])

// ------------------------------------------------------------------ profiles

const rawProfiles = {
  profiles: [
    { name: 'Grammar', title: 'Spelling', system: 'fix it' },
    { name: 'Empty', title: 'Empty', system: '   ' },
    { name: '', title: 'Nameless', system: 'nameless' },
    { name: 'Grammar', title: 'Duplicate', system: 'duplicate' },
    'not an object',
    { name: 'Formal', system: 'be formal' }
  ]
}

check('profiles drop the unusable and the duplicated',
  Model.normalizeProfiles(rawProfiles),
  [{ name: 'Grammar', title: 'Spelling', icon: '', system: 'fix it' },
   { name: 'Formal', title: 'Formal', icon: '', system: 'be formal' }])
check('a missing profiles array is empty, not a throw',
  Model.normalizeProfiles({}), [])
check('null is empty', Model.normalizeProfiles(null), [])

// A file written before titles existed still has to render: the tile shows
// the name rather than an empty square.
check('a missing title falls back to the name',
  Model.normalizeProfiles({ profiles: [{ name: 'Formal', system: 'x' }] })[0].title, 'Formal')
check('a blank title falls back to the name',
  Model.normalizeProfiles({ profiles: [{ name: 'Formal', title: '  ', system: 'x' }] })[0].title, 'Formal')

const profiles = Model.normalizeProfiles(rawProfiles)
check('the named profile wins', Model.resolveProfile(profiles, 'Formal').system, 'be formal')
// No fallback: a correction that ran with a prompt the user did not choose is
// a wrong answer that looks like a right one, and it cost an afternoon to tell
// apart from a real bug once already.
check('an unknown name resolves to nothing',
  Model.resolveProfile(profiles, 'Deleted'), null)
check('no profiles resolves to null', Model.resolveProfile([], 'Grammar'), null)

// ---- Icons. Optional, and with no fallback: a prompt without one shows its
// title alone, the way every tile looked before icons existed.
check('an icon survives normalizing',
  Model.normalizeProfiles({ profiles: [{ name: 'a', icon: '\u{F03EB}', system: 's' }] })[0].icon,
  '\u{F03EB}')
check('a missing icon is empty, not a fallback',
  Model.normalizeProfiles({ profiles: [{ name: 'a', system: 's' }] })[0].icon, '')
check('a blank icon is empty',
  Model.normalizeProfiles({ profiles: [{ name: 'a', icon: '  ', system: 's' }] })[0].icon, '')
check('hasIcon is false without one', Model.hasIcon({ name: 'a', icon: '' }), false)
check('hasIcon is true with one', Model.hasIcon({ name: 'a', icon: '\u{F03EB}' }), true)
check('hasIcon copes with nothing', Model.hasIcon(null), false)
// ---- Icon search. The names come from the font, so "pencil" has to beat
// "pencil_square" and the family prefix must not get in the way.
const iconFixture = [
  ['a', 'fa-pencil_square_o'],
  ['b', 'md-pencil'],
  ['c', 'oct-repo'],
  ['d', 'md-broom'],
  ['e', 'md-file_pencil'],
  ['f', 'fa-pencil']
]

check('an exact name wins, prefix or not',
  Model.filterIcons(iconFixture, 'pencil', 10).map(function (e) { return e[1] })[0],
  'md-pencil')
check('a word boundary beats a substring',
  Model.filterIcons(iconFixture, 'pencil', 10).map(function (e) { return e[1] }),
  ['md-pencil', 'fa-pencil', 'fa-pencil_square_o', 'md-file_pencil'])
check('search is case-insensitive',
  Model.filterIcons(iconFixture, 'BROOM', 10).map(function (e) { return e[1] }), ['md-broom'])
check('an empty query lists from the top',
  Model.filterIcons(iconFixture, '', 2).length, 2)
check('whitespace is not a query',
  Model.filterIcons(iconFixture, '   ', 3).length, 3)
check('no match is empty, not everything',
  Model.filterIcons(iconFixture, 'zzzz', 10), [])
// The grid is rebuilt on every keystroke, so the cap is load-bearing.
check('the limit is honoured', Model.filterIcons(iconFixture, 'pencil', 2).length, 2)
check('a missing list is empty', Model.filterIcons(null, 'x', 10), [])
check('malformed entries are skipped',
  Model.filterIcons([['g'], null, ['h', 'md-pencil']], 'pencil', 10).length, 1)

// The shipped icons.json is a generated data file the panel depends on, so a
// regeneration that produced nothing has to fail here rather than in the UI.
const shippedIcons = JSON.parse(
  require('fs').readFileSync(path.join(__dirname, '..', 'icons.json'), 'utf8')).icons
check('icons.json carries a real list', shippedIcons.length > 5000, true)
check('every entry is [glyph, name]',
  shippedIcons.filter(function (e) {
    return !Array.isArray(e) || e.length !== 2 || Array.from(e[0]).length !== 1 || !e[1]
  }).length, 0)
check('a familiar icon is findable',
  Model.filterIcons(shippedIcons, 'md-pencil', 1).map(function (e) { return e[1] }), ['md-pencil'])

check('a title is looked up by name', Model.profileTitle(profiles, 'Grammar'), 'Spelling')
check('a profile object is accepted directly',
  Model.profileTitle(profiles, profiles[1]), 'Formal')
// The settings can name a profile that no longer exists; the label shown must
// not silently become the first profile's.
check('an unknown name keeps its own label', Model.profileTitle([], 'Deleted'), 'Deleted')

// ---- Names generated for new profiles.

check('a name is slugged from the title', Model.profileName('Kürzen und straffen', []), 'k-rzen-und-straffen')
check('a taken name is suffixed', Model.profileName('Formal', ['formal']), 'formal-2')
check('suffixes keep counting', Model.profileName('Formal', ['formal', 'formal-2']), 'formal-3')
check('profile objects count as taken', Model.profileName('Formal', [{ name: 'formal' }]), 'formal-2')
check('a title with no letters still yields a name', Model.profileName('!!!', []), 'prompt')
check('an empty title still yields a name', Model.profileName('', []), 'prompt')

// ---------------------------------------------------------------- the grid

check('one prompt is one column', Model.gridColumns(1), 1)
check('three prompts are 2x2', Model.gridColumns(3), 2)
check('four prompts are 2x2', Model.gridColumns(4), 2)
check('five prompts are 3 wide', Model.gridColumns(5), 3)
check('nine prompts are 3x3', Model.gridColumns(9), 3)
check('ten prompts are 4 wide', Model.gridColumns(10), 4)
check('no prompts still has a column', Model.gridColumns(0), 1)

// Clamped, never wrapped: a held arrow key stops at the edge instead of
// reappearing somewhere the eye did not follow.
check('right moves along the row', Model.moveIndex(0, 1, 0, 9, 3), 1)
check('right stops at the row end', Model.moveIndex(2, 1, 0, 9, 3), 2)
check('left stops at the row start', Model.moveIndex(3, -1, 0, 9, 3), 3)
check('down moves a whole row', Model.moveIndex(1, 0, 1, 9, 3), 4)
check('up moves a whole row', Model.moveIndex(4, 0, -1, 9, 3), 1)
check('up stops in the top row', Model.moveIndex(1, 0, -1, 9, 3), 1)
check('down stops in the bottom row', Model.moveIndex(7, 0, 1, 9, 3), 7)
// Five tiles in a 3-wide grid leave the bottom row half empty. Down from the
// tile above the gap lands on the last tile, not on nothing.
check('down out of a ragged row lands on the last tile', Model.moveIndex(2, 0, 1, 5, 3), 4)
check('down from the last tile stays put', Model.moveIndex(4, 0, 1, 5, 3), 4)
check('right into the ragged gap stays put', Model.moveIndex(4, 1, 0, 5, 3), 4)
check('an out-of-range index is pulled back in', Model.moveIndex(99, 0, 0, 5, 3), 4)
check('an empty grid stays at zero', Model.moveIndex(0, 1, 0, 0, 1), 0)

// ------------------------------------------------------------------- history

const run = {
  ts: 1700000000,
  profile: 'Grammar',
  backend: 'anthropic',
  model: 'claude-opus-5',
  ms: 1234,
  original: 'i has bad grammer',
  corrected: 'I have bad grammar',
  usage: { input_tokens: 10, output_tokens: 9 }
}

const withText = Model.historyEntry(run, { storeText: true })
check('an entry keeps both versions when asked',
  [withText.original, withText.corrected], [run.original, run.corrected])
check('an entry records the lengths',
  [withText.originalLength, withText.correctedLength], [17, 18])
check('an entry notes that something changed', withText.changed, true)

const withoutText = Model.historyEntry(run, { storeText: false })
// The whole point of the metadata-only mode: nothing quotable on disk.
check('metadata-only keeps no text',
  [withoutText.original, withoutText.corrected], [undefined, undefined])
check('metadata-only keeps the lengths',
  [withoutText.originalLength, withoutText.correctedLength], [17, 18])
check('metadata-only still knows it changed', withoutText.changed, true)
check('metadata-only keeps usage', withoutText.usage, run.usage)

check('an unchanged run is marked as such',
  Model.historyEntry({ ts: 1, original: 'same', corrected: 'same' }, {}).changed, false)

check('hasText is false for a metadata-only entry', Model.hasText(withoutText), false)
check('hasText is true for a full entry', Model.hasText(withText), true)
check('hasText tolerates null', Model.hasText(null), false)

check('append puts the newest first',
  Model.appendHistory([{ ts: 1 }, { ts: 2 }], { ts: 3 }, 10).map(e => e.ts), [3, 1, 2])
check('append trims to the limit',
  Model.appendHistory([{ ts: 1 }, { ts: 2 }], { ts: 3 }, 2).map(e => e.ts), [3, 1])
check('a zero limit keeps nothing',
  Model.appendHistory([{ ts: 1 }], { ts: 2 }, 0), [])
check('trim leaves a short list alone',
  Model.trimHistory([{ ts: 1 }], 50).length, 1)
check('trim copies rather than mutating', (() => {
  const original = [{ ts: 1 }, { ts: 2 }]
  Model.trimHistory(original, 1)
  return original.length
})(), 2)

// ------------------------------------------------------------------ display

check('a short summary is untouched', Model.summarize('hello', 20), 'hello')
// A marked paragraph arrives with its line breaks; the list is one row tall.
check('newlines collapse to spaces', Model.summarize('a\nb\n\nc', 20), 'a b c')
check('leading space is dropped', Model.summarize('   padded  ', 20), 'padded')
check('a long summary is cut at a word boundary',
  Model.summarize('the quick brown fox jumps', 16), 'the quick brown…')
check('summary defaults to 60', Model.summarize('x'.repeat(80)).length, 60)
check('summary tolerates null', Model.summarize(null, 10), '')

check('sub-second durations are milliseconds', Model.formatDuration(432), '432 ms')
check('longer durations are seconds', Model.formatDuration(1234), '1.2 s')
check('a missing duration is blank', Model.formatDuration(null), '')
check('a negative duration is blank', Model.formatDuration(-1), '')

check('usage reads as in/out', Model.formatUsage({ input_tokens: 10, output_tokens: 9 }), '10 in / 9 out')
check('a half-known usage still renders', Model.formatUsage({ input_tokens: 10 }), '10 in / ? out')
check('no usage is blank', Model.formatUsage(null), '')
check('an empty usage object is blank', Model.formatUsage({}), '')

// ------------------------------------------------------------------- errors

check('no selection has its own sentence',
  Model.errorMessage(Model.EXIT_NO_SELECTION, ''), 'Nothing selected.')
check('a config failure names the category',
  Model.errorMessage(Model.EXIT_CONFIG, 'No Anthropic API key.'),
  'Backend is not configured. No Anthropic API key.')
check('an upstream failure carries the detail',
  Model.errorMessage(Model.EXIT_UPSTREAM, 'Anthropic returned 529'),
  'The model could not be reached. Anthropic returned 529')
check('a timeout says so', Model.errorMessage(Model.EXIT_TIMEOUT, ''), 'Timed out.')
check('an unknown code still produces a sentence',
  Model.errorMessage(42, ''), 'Correction failed.')
// Adapters are allowed to be chatty on stderr; the last line is the verdict.
check('only the last stderr line is shown',
  Model.errorMessage(Model.EXIT_UPSTREAM, 'warning: retrying\n\nreal problem here\n'),
  'The model could not be reached. real problem here')
check('a blank stderr leaves just the sentence',
  Model.errorMessage(Model.EXIT_UPSTREAM, '   \n  '), 'The model could not be reached.')
check('the headline drops the detail',
  Model.errorHeadline(Model.EXIT_CONFIG), 'Backend is not configured.')

// -------------------------------------------------------------------- report

if (failures.length > 0) {
  console.error(`FAILED ${failures.length}/${checks}`)
  failures.forEach(f => console.error('  - ' + f))
  process.exit(1)
}
console.log(`ok    ${checks} checks`)
