#!/usr/bin/env python3
"""Tests for the `scribe` CLI, driven through stub backends.

Every test runs against a throwaway XDG_CONFIG_HOME / XDG_STATE_HOME, so the
real profiles and the real history are never touched and the suite is safe to
run on the machine the plugin is installed on. No test reaches the network:
the backends here are three-line scripts.

Run: python3 -B tests/cli-test.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SCRIBE = os.path.join(PLUGIN_DIR, "scribe")

EXIT_OK = 0
EXIT_USAGE = 1
EXIT_CONFIG = 2
EXIT_UPSTREAM = 3
EXIT_NO_SELECTION = 4
EXIT_TIMEOUT = 5

# Backends written as source so a test can name the behaviour it needs.
STUBS = {
    # Echoes the text back with a marker, so a test can tell a real answer
    # from a passthrough.
    "echo": """#!/usr/bin/env python3
import json, sys
if "--check" in sys.argv[1:]:
    print("echo needs nothing"); sys.exit(0)
p = json.load(sys.stdin)
json.dump({"text": p["text"].replace("teh", "the"), "model": "echo-1",
           "usage": {"input_tokens": 3, "output_tokens": 4}}, sys.stdout)
""",
    # Answers with the system prompt it was given, so a test can assert which
    # profile actually reached the backend.
    "reflect": """#!/usr/bin/env python3
import json, sys
p = json.load(sys.stdin)
json.dump({"text": json.dumps({"system": p["system"], "model": p["model"],
                               "timeoutSec": p["timeoutSec"]})}, sys.stdout)
""",
    "fenced": """#!/usr/bin/env python3
import json, sys
json.dump({"text": "```\\ncorrected text\\n```"}, sys.stdout)
""",
    "trailing": """#!/usr/bin/env python3
import json, sys
json.dump({"text": "corrected text\\n\\n"}, sys.stdout)
""",
    "empty": """#!/usr/bin/env python3
import json, sys
json.dump({"text": "   "}, sys.stdout)
""",
    "noconfig": """#!/usr/bin/env python3
import sys
print("No API key. Run: secret-tool store ...", file=sys.stderr)
sys.exit(2)
""",
    "broken": """#!/usr/bin/env python3
import sys
print("upstream exploded", file=sys.stderr)
sys.exit(3)
""",
    "garbage": """#!/usr/bin/env python3
print("this is not json")
""",
    "wrongshape": """#!/usr/bin/env python3
import json, sys
json.dump({"answer": "wrong key"}, sys.stdout)
""",
    "slow": """#!/usr/bin/env python3
import time
time.sleep(30)
""",
}


class ScribeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="scribe-test-")
        self.config = os.path.join(self.tmp, "config")
        self.state = os.path.join(self.tmp, "state")
        self.backends = os.path.join(self.config, "omarchy", "scribe", "backends")
        os.makedirs(self.backends)
        for name, source in STUBS.items():
            path = os.path.join(self.backends, name)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(source)
            os.chmod(path, 0o755)

        self.env = dict(os.environ)
        self.env["XDG_CONFIG_HOME"] = self.config
        self.env["XDG_STATE_HOME"] = self.state

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_scribe(self, *args, stdin=""):
        return subprocess.run(
            [sys.executable, SCRIBE] + list(args),
            input=stdin,
            capture_output=True,
            text=True,
            env=self.env,
            timeout=60,
        )

    def correct(self, text, *extra):
        return self.run_scribe(
            "run", "--stdin", "--json", "--no-copy", "--no-notify", *extra, stdin=text
        )

    # ------------------------------------------------------------- happy path

    def test_corrects_and_reports(self):
        result = self.correct("teh cat", "--backend", "echo")
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["corrected"], "the cat")
        self.assertEqual(payload["original"], "teh cat")
        self.assertTrue(payload["changed"])
        self.assertEqual(payload["model"], "echo-1")
        self.assertEqual(payload["usage"], {"input_tokens": 3, "output_tokens": 4})
        self.assertFalse(payload["copied"])

    def test_bare_output_is_just_the_text(self):
        """Without --json the CLI is a filter, so it can sit in a pipeline."""
        result = self.run_scribe(
            "run", "--stdin", "--no-copy", "--no-notify", "--backend", "echo", stdin="teh cat"
        )
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        self.assertEqual(result.stdout, "the cat\n")

    def test_unchanged_text_is_marked_as_such(self):
        result = self.correct("the cat", "--backend", "echo")
        self.assertFalse(json.loads(result.stdout)["changed"])

    # ------------------------------------------------------------- profiles

    def test_default_profile_reaches_the_backend(self):
        result = self.correct("x", "--backend", "reflect")
        sent = json.loads(json.loads(result.stdout)["corrected"])
        self.assertIn("correct spelling, grammar and punctuation", sent["system"])

    def test_named_profile_is_used(self):
        result = self.correct("x", "--backend", "reflect", "--profile", "Formal")
        sent = json.loads(json.loads(result.stdout)["corrected"])
        self.assertIn("formal", sent["system"].lower())

    def test_unknown_profile_falls_back_rather_than_failing(self):
        result = self.correct("x", "--backend", "reflect", "--profile", "Deleted")
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)

    def test_profiles_are_seeded_on_first_run(self):
        path = os.path.join(self.config, "omarchy", "scribe", "profiles.json")
        self.assertFalse(os.path.exists(path))
        self.run_scribe("profiles")
        self.assertTrue(os.path.exists(path))
        with open(path, encoding="utf-8") as handle:
            names = [p["name"] for p in json.load(handle)["profiles"]]
        self.assertEqual(names, ["Grammar", "Grammar + style", "Formal"])

    def test_hand_edited_profiles_are_not_overwritten(self):
        path = os.path.join(self.config, "omarchy", "scribe", "profiles.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"profiles": [{"name": "Mine", "system": "do my thing"}]}, handle)
        result = self.run_scribe("profiles")
        self.assertEqual(result.stdout.strip(), "Mine")

    def test_corrupt_profiles_fall_back_to_the_builtins(self):
        """A half-saved profiles.json must not block a correction."""
        path = os.path.join(self.config, "omarchy", "scribe", "profiles.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("{ this is not json")
        result = self.run_scribe("profiles")
        self.assertEqual(result.returncode, EXIT_OK)
        self.assertIn("Grammar", result.stdout)

    def test_the_selection_is_tagged_as_data(self):
        """The prompt-injection guard the profiles rely on has to be real."""
        result = self.correct("x", "--backend", "reflect")
        sent = json.loads(json.loads(result.stdout)["corrected"])
        self.assertIn("<text>", sent["system"])
        self.assertIn("Never", sent["system"])

    # -------------------------------------------------------------- failures

    def test_empty_stdin_is_not_a_correction(self):
        result = self.correct("   \n  ", "--backend", "echo")
        self.assertEqual(result.returncode, EXIT_NO_SELECTION)

    def test_unknown_backend_is_a_config_error(self):
        result = self.correct("x", "--backend", "nosuch")
        self.assertEqual(result.returncode, EXIT_CONFIG)
        self.assertIn("nosuch", result.stderr)

    def test_a_path_as_a_backend_name_is_refused(self):
        """The name arrives from a hand-edited shell.json; it is not a path."""
        result = self.correct("x", "--backend", "../../bin/sh")
        self.assertEqual(result.returncode, EXIT_CONFIG)

    def test_non_executable_backend_names_the_fix(self):
        path = os.path.join(self.backends, "notexec")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\n")
        os.chmod(path, 0o644)
        result = self.correct("x", "--backend", "notexec")
        self.assertEqual(result.returncode, EXIT_CONFIG)
        self.assertIn("chmod +x", result.stderr)

    def test_config_exit_code_is_passed_through(self):
        """An adapter saying "you have no key" must not read as a network blip."""
        result = self.correct("x", "--backend", "noconfig")
        self.assertEqual(result.returncode, EXIT_CONFIG)
        self.assertIn("secret-tool", result.stderr)

    def test_upstream_exit_code_is_passed_through(self):
        result = self.correct("x", "--backend", "broken")
        self.assertEqual(result.returncode, EXIT_UPSTREAM)
        self.assertIn("upstream exploded", result.stderr)

    def test_non_json_from_a_backend_is_upstream(self):
        result = self.correct("x", "--backend", "garbage")
        self.assertEqual(result.returncode, EXIT_UPSTREAM)

    def test_missing_text_field_is_upstream(self):
        result = self.correct("x", "--backend", "wrongshape")
        self.assertEqual(result.returncode, EXIT_UPSTREAM)

    def test_blank_correction_is_refused(self):
        """Whitespace must never reach the clipboard as a "correction"."""
        result = self.correct("x", "--backend", "empty")
        self.assertEqual(result.returncode, EXIT_UPSTREAM)

    def test_timeout_has_its_own_code(self):
        result = self.correct("x", "--backend", "slow", "--timeout", "1")
        self.assertEqual(result.returncode, EXIT_TIMEOUT)

    def test_timeout_reaches_the_backend(self):
        result = self.correct("x", "--backend", "reflect", "--timeout", "7")
        sent = json.loads(json.loads(result.stdout)["corrected"])
        self.assertEqual(sent["timeoutSec"], 7)

    # -------------------------------------------------------------- unwrap

    def test_a_stray_code_fence_is_removed(self):
        result = self.correct("plain text", "--backend", "fenced")
        self.assertEqual(json.loads(result.stdout)["corrected"], "corrected text")

    def test_a_fence_is_kept_when_the_original_had_one(self):
        """Correcting a fenced snippet must not eat its fence."""
        result = self.correct("```\nsome code\n```", "--backend", "fenced")
        self.assertEqual(json.loads(result.stdout)["corrected"], "```\ncorrected text\n```")

    def test_trailing_newlines_match_the_original(self):
        result = self.correct("no trailing newline", "--backend", "trailing")
        self.assertEqual(json.loads(result.stdout)["corrected"], "corrected text")

    def test_a_trailing_newline_is_restored_when_the_original_had_one(self):
        result = self.correct("had one\n", "--backend", "echo")
        self.assertTrue(json.loads(result.stdout)["corrected"].endswith("\n"))

    # -------------------------------------------------------------- history

    def history(self):
        result = self.run_scribe("history")
        return json.loads(result.stdout)["entries"]

    def test_a_run_is_recorded(self):
        self.correct("teh cat", "--backend", "echo")
        entries = self.history()
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["corrected"], "the cat")
        self.assertEqual(entries[0]["backend"], "echo")
        self.assertEqual(entries[0]["source"], "stdin")

    def test_history_is_newest_first(self):
        self.correct("teh one", "--backend", "echo")
        self.correct("teh two", "--backend", "echo")
        self.assertEqual(self.history()[0]["corrected"], "the two")

    def test_history_respects_the_limit(self):
        for i in range(4):
            self.correct("teh %d" % i, "--backend", "echo")
        self.assertEqual(len(self.history()), 4)
        self.correct("teh last", "--backend", "echo", "--history-limit", "2")
        self.assertEqual(len(self.history()), 2)

    def test_metadata_only_writes_no_text(self):
        """The privacy switch has to actually keep text off the disk."""
        self.correct("teh secret", "--backend", "echo", "--history-metadata-only")
        entry = self.history()[0]
        self.assertNotIn("original", entry)
        self.assertNotIn("corrected", entry)
        self.assertEqual(entry["correctedLength"], len("the secret"))
        with open(os.path.join(self.state, "omarchy", "scribe", "history.json"), encoding="utf-8") as h:
            self.assertNotIn("secret", h.read())

    def test_no_history_writes_no_file(self):
        self.correct("teh cat", "--backend", "echo", "--no-history")
        self.assertFalse(os.path.exists(os.path.join(self.state, "omarchy", "scribe", "history.json")))

    def test_history_file_is_private(self):
        self.correct("teh cat", "--backend", "echo")
        path = os.path.join(self.state, "omarchy", "scribe", "history.json")
        self.assertEqual(oct(os.stat(path).st_mode & 0o777), oct(0o600))

    def test_history_clear_empties_it(self):
        self.correct("teh cat", "--backend", "echo")
        self.run_scribe("history", "clear")
        self.assertEqual(self.history(), [])

    def test_a_failed_run_is_not_recorded(self):
        self.correct("x", "--backend", "broken")
        self.assertEqual(self.history(), [])

    # -------------------------------------------------------------- listings

    def test_backends_lists_shipped_and_user_adapters(self):
        names = json.loads(self.run_scribe("backends", "--json").stdout)["backends"]
        self.assertIn("anthropic", names)     # shipped
        self.assertIn("echo", names)          # user directory
        self.assertNotIn("README.md", names)  # not executable

    def test_doctor_reports_a_working_backend(self):
        result = self.run_scribe("doctor", "--backend", "echo")
        self.assertEqual(result.returncode, EXIT_OK, result.stdout)
        self.assertIn("echo needs nothing", result.stdout)

    def test_doctor_fails_on_a_missing_backend(self):
        result = self.run_scribe("doctor", "--backend", "nosuch")
        self.assertEqual(result.returncode, EXIT_CONFIG)


if __name__ == "__main__":
    unittest.main(verbosity=0, buffer=True)
