# The backend contract

A backend is any executable that reads one JSON object on stdin and writes one
JSON object on stdout. Nothing about it is Python-specific; a shell script, a
Go binary or a two-line `jq` pipeline all qualify.

Scribe looks for the name in `barWidget.backend` in two places, first match
wins:

1. `~/.config/omarchy/scribe/backends/<name>`
2. `<plugin dir>/backends/<name>`

The user directory comes first, so a hand-written adapter shadows a shipped
one without touching the repo. The name must be a plain file name matching
`[A-Za-z0-9][A-Za-z0-9._-]*` — Scribe refuses anything with a slash in it
rather than trying to sanitize a path that arrived from a hand-edited
`shell.json`.

## Input (stdin)

```json
{
  "system": "You correct spelling, grammar and punctuation. …",
  "text": "the text the user marked, verbatim",
  "model": "claude-opus-5",
  "timeoutSec": 30,
  "options": {}
}
```

`text` is exactly what was on the selection: no trimming, no escaping, no
length cap. `options` is a free-form object reserved for per-backend settings;
the shipped adapters read at most `options.effort` from it.

`model` is passed through verbatim and means whatever the backend wants it to
mean — `claude-opus-5` for the Anthropic adapter, `opus` for the `claude` CLI,
`llama3.2` for an ollama endpoint.

## Output (stdout)

```json
{
  "text": "the corrected text",
  "model": "claude-opus-5",
  "usage": { "input_tokens": 412, "output_tokens": 389 }
}
```

`text` is required and must be the corrected text alone. `model` and `usage`
are optional; when `usage` is absent the panel simply shows no token count for
that entry.

Scribe post-processes `text` only where a model has demonstrably ignored the
prompt in an unambiguous way: it unwraps a ``` fence when the original had
none, and it matches the original's leading and trailing newlines. It will not
try to repair anything subtler — a corrector that rewrites its own model's
answer is a corrector that corrupts text.

## Exit codes

| code | meaning | what Scribe does |
|---|---|---|
| `0` | success | reads stdout |
| `2` | configuration problem — no key, no endpoint, not installed | shows the stderr line; the panel treats it as "fix your setup" |
| `3` | upstream problem — network, HTTP error, unusable answer | shows the stderr line as a transient failure |

Any other non-zero code is treated as `3`.

On failure, write **one human-readable line** to stderr. It is shown to the
user verbatim, so name the fix where you can: "No Anthropic API key. Either
export ANTHROPIC_API_KEY, or store one with: secret-tool store …" is a good
line, "Error: 401" is not.

## `--check`

If invoked with `--check`, a backend must verify its configuration *without
calling the model* and without reading stdin — resolve the credential, confirm
the binary exists, that sort of thing. Exit `0` with a one-line summary on
stdout, or exit `2` with the fix on stderr. `scribe doctor` calls this.

A backend that does not implement `--check` still works; `scribe doctor` just
reports the credential check as failed.

## Prompt injection

The text being corrected is untrusted. It arrives from whatever the user
happened to highlight — an email, a web page, a diff — and it can contain
sentences addressed to the model. The shipped profiles tell the model that
everything inside the `<text>` tags is data and never an instruction, and the
shipped adapters wrap the text in those tags before sending it.

If you write your own adapter, keep the wrapping. A backend that pastes the
raw selection into the prompt with no delimiter is one marked-up mailing list
post away from following someone else's instructions.

## Shipped backends

| name | credentials | notes |
|---|---|---|
| `anthropic` | `ANTHROPIC_API_KEY`, else `secret-tool lookup service anthropic account api-key` | the default; ~1s at `effort: low` |
| `claude-cli` | none — uses whatever `claude` is logged in with | a few seconds slower (node startup); counts against subscription usage |
| `openai` | `SCRIBE_OPENAI_API_KEY` / `OPENAI_API_KEY`, else the keyring; not required for localhost | set `SCRIBE_OPENAI_BASE_URL` for ollama, llama.cpp, LM Studio, OpenRouter, … |

## A minimal backend

```bash
#!/usr/bin/env bash
# ~/.config/omarchy/scribe/backends/upper — shouts instead of correcting.
set -euo pipefail
[[ "${1:-}" == "--check" ]] && { echo "no configuration needed"; exit 0; }
jq -c '{text: (.text | ascii_upcase)}'
```

`chmod +x` it, set the backend to `upper` in the panel, and the next
correction goes through it. That is also the fastest way to test the rest of
the pipeline without spending a token.
