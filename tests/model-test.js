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
    { name: 'Grammar', system: 'fix it' },
    { name: 'Empty', system: '   ' },
    { name: '', system: 'nameless' },
    { name: 'Grammar', system: 'duplicate' },
    'not an object',
    { name: 'Formal', system: 'be formal' }
  ]
}

check('profiles drop the unusable and the duplicated',
  Model.normalizeProfiles(rawProfiles),
  [{ name: 'Grammar', system: 'fix it' }, { name: 'Formal', system: 'be formal' }])
check('a missing profiles array is empty, not a throw',
  Model.normalizeProfiles({}), [])
check('null is empty', Model.normalizeProfiles(null), [])

const profiles = Model.normalizeProfiles(rawProfiles)
check('the named profile wins', Model.resolveProfile(profiles, 'Formal').system, 'be formal')
// A renamed profile must not block a correction: running with the wrong
// prompt is recoverable, refusing to run is just an obstacle.
check('an unknown name falls back to the first',
  Model.resolveProfile(profiles, 'Deleted').name, 'Grammar')
check('no profiles resolves to null', Model.resolveProfile([], 'Grammar'), null)

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
