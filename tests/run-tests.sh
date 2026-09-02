#!/usr/bin/env bash
# Runs every test in the repo. No arguments, no options, no network.
set -uo pipefail

cd "$(dirname "$0")/.."
status=0

run() {
  local label="$1"; shift
  printf '%-24s' "$label"
  if out=$("$@" 2>&1); then
    echo "$out" | tail -1
  else
    echo "FAILED"
    echo "$out" | sed 's/^/    /'
    status=1
  fi
}

# -B: no __pycache__ next to the sources.
run "scribe CLI (python)" python3 -B tests/cli-test.py
run "backends (python)" python3 -B tests/contract-test.py

if command -v node >/dev/null 2>&1; then
  run "Model.js (node)" node tests/model-test.js
else
  printf '%-24sSKIPPED (node not installed)\n' "Model.js (node)"
fi

printf '%-24s' "manifest.json"
if python3 -c 'import json,sys; d=json.load(open("manifest.json"));
missing=[k for k in ("schemaVersion","id","name","version","author","license",
                     "description","kinds","entryPoints") if k not in d];
sys.exit("missing keys: %s" % missing if missing else 0)' 2>&1; then
  echo "ok    valid json, required keys present"
else
  echo "FAILED"; status=1
fi

# The manifest names the QML entry point and the defaults the panel reads;
# a rename that updates one and not the other is silent until runtime.
printf '%-24s' "manifest wiring"
if wiring=$(python3 -c '
import json, os, sys, re
m = json.load(open("manifest.json"))
entry = m["entryPoints"]["barWidget"]
if not os.path.exists(entry):
    sys.exit("entryPoints.barWidget points at a missing file: %s" % entry)
qml = open(entry).read()
if ("moduleName: \"%s\"" % m["id"]) not in qml:
    sys.exit("%s does not set moduleName to %s" % (entry, m["id"]))
if ("ipcTarget: \"%s\"" % m["id"]) not in qml:
    sys.exit("%s does not set ipcTarget to %s" % (entry, m["id"]))
defaults = set(m["barWidget"]["defaults"])
declared = {e["key"] for e in m["barWidget"]["schema"]}
if defaults != declared:
    sys.exit("defaults and schema disagree: %s" % (defaults ^ declared))
read = set(re.findall(r"setting\(\"([A-Za-z]+)\"", qml))
missing = defaults - read
if missing:
    sys.exit("declared but never read by %s: %s" % (entry, sorted(missing)))
print("ok    %d settings, entry point wired" % len(defaults))
' 2>&1); then
  echo "$wiring"
else
  echo "FAILED"; echo "$wiring" | sed 's/^/    /'; status=1
fi

# Only where a Qt toolchain is around; the import warnings for qs.Commons /
# qs.Ui are expected here, so this looks for parse errors alone.
QMLLINT=$(command -v qmllint || echo /usr/lib/qt6/bin/qmllint)
printf '%-24s' "qml syntax"
if [[ -x "$QMLLINT" ]]; then
  if "$QMLLINT" --compiler disable Panel.qml 2>&1 \
      | grep -qiE 'syntax|unexpected token|expected token'; then
    echo "FAILED"
    "$QMLLINT" --compiler disable Panel.qml 2>&1 \
      | grep -iE 'syntax|unexpected token|expected token' | sed 's/^/    /'
    status=1
  else
    echo "ok    no parse errors"
  fi
else
  echo "SKIPPED (qmllint not installed)"
fi

exit $status
