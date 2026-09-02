#!/usr/bin/env python3
"""Tests for the shipped backend adapters.

Nothing here touches the network. The Anthropic and OpenAI adapters are
imported as modules and their `urlopen` is replaced, so the request body can
be asserted field by field -- which is the point: the Messages API has moved
under this code before (budget_tokens removed, temperature rejected, effort
moved into output_config), and a wrong field is a 400 the user sees as "the
model could not be reached".

Run: python3 -B tests/contract-test.py
"""

import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
BACKEND_DIR = os.path.join(PLUGIN_DIR, "backends")
SHIPPED = ["anthropic", "claude-cli", "openai"]


def load(name):
    """Import an extensionless executable as a module."""
    path = os.path.join(BACKEND_DIR, name)
    spec = importlib.util.spec_from_loader(
        "backend_" + name.replace("-", "_"),
        importlib.machinery.SourceFileLoader("backend_" + name.replace("-", "_"), path),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class ShippedAdapterShape(unittest.TestCase):
    """Contract properties every shipped adapter must have."""

    def setUp(self):
        # An empty PATH directory hides secret-tool and `claude` so every
        # adapter takes its unconfigured branch. The adapters are invoked
        # through sys.executable rather than their shebang, which would need
        # `env` on PATH to resolve python3 at all.
        self.emptybin = tempfile.mkdtemp(prefix="scribe-nobin-")
        self.env = {
            **os.environ,
            "PATH": self.emptybin,
            "ANTHROPIC_API_KEY": "",
            "OPENAI_API_KEY": "",
            "SCRIBE_OPENAI_API_KEY": "",
            "SCRIBE_OPENAI_BASE_URL": "https://api.openai.com/v1",
        }

    def tearDown(self):
        os.rmdir(self.emptybin)

    def check(self, name):
        return subprocess.run(
            [sys.executable, os.path.join(BACKEND_DIR, name), "--check"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20, env=self.env,
        )

    def test_all_are_executable(self):
        for name in SHIPPED:
            path = os.path.join(BACKEND_DIR, name)
            self.assertTrue(os.access(path, os.X_OK), "%s is not executable" % name)

    def test_all_answer_check_without_reading_stdin(self):
        """`scribe doctor` calls --check with no stdin; a read would hang."""
        for name in SHIPPED:
            with self.subTest(backend=name):
                result = self.check(name)
                # Either configured (0) or a config problem (2) -- never a
                # crash, and never an upstream code.
                self.assertIn(result.returncode, (0, 2), result.stderr)

    def test_unconfigured_is_exit_2_not_exit_3(self):
        """A missing key must read as "fix your setup", not "network blip"."""
        for name in SHIPPED:
            with self.subTest(backend=name):
                result = self.check(name)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertTrue(result.stderr.strip(), "%s said nothing on stderr" % name)


class AnthropicAdapter(unittest.TestCase):
    def setUp(self):
        self.mod = load("anthropic")
        self.captured = {}

        def fake_urlopen(request, timeout=None):
            self.captured["url"] = request.full_url
            self.captured["headers"] = {k.lower(): v for k, v in request.headers.items()}
            self.captured["body"] = json.loads(request.data.decode("utf-8"))
            self.captured["timeout"] = timeout
            return FakeResponse(json.dumps(self.reply).encode("utf-8"))

        self.mod.urllib.request.urlopen = fake_urlopen
        self.reply = {
            "model": "claude-opus-5",
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": "the cat"}],
            "usage": {"input_tokens": 12, "output_tokens": 9},
        }

    def call(self, **overrides):
        payload = {"system": "fix it", "text": "teh cat", "model": "claude-opus-5",
                   "timeoutSec": 30, "options": {}}
        payload.update(overrides)
        return self.mod.call(payload, "sk-ant-test")

    # ------------------------------------------------------- request shape

    def test_endpoint_and_headers(self):
        self.call()
        self.assertEqual(self.captured["url"], "https://api.anthropic.com/v1/messages")
        headers = self.captured["headers"]
        self.assertEqual(headers["x-api-key"], "sk-ant-test")
        self.assertEqual(headers["anthropic-version"], "2023-06-01")

    def test_no_removed_parameters(self):
        """These are 400s on Opus 5, not warnings."""
        self.call()
        body = self.captured["body"]
        self.assertNotIn("temperature", body)
        self.assertNotIn("top_p", body)
        self.assertNotIn("top_k", body)
        self.assertNotIn("budget_tokens", json.dumps(body))

    def test_thinking_is_left_alone(self):
        """Adaptive thinking is on by default on Opus 5, and disabling it has
        two documented failure modes: tool calls leaking into visible text and
        <thinking> tags in the response. The parameter belongs absent."""
        self.call()
        self.assertNotIn("thinking", self.captured["body"])

    def test_effort_lives_inside_output_config(self):
        self.call()
        self.assertEqual(self.captured["body"]["output_config"], {"effort": "low"})

    def test_effort_is_overridable(self):
        self.call(options={"effort": "high"})
        self.assertEqual(self.captured["body"]["output_config"]["effort"], "high")

    def test_refusal_fallback_is_declared(self):
        """Header and body have to agree or the request is rejected."""
        self.call()
        self.assertEqual(self.captured["headers"]["anthropic-beta"], self.mod.FALLBACK_BETA)
        self.assertEqual(self.captured["body"]["fallbacks"], "default")

    def test_the_selection_is_tagged(self):
        self.call()
        content = self.captured["body"]["messages"][0]["content"]
        self.assertEqual(content, "<text>\nteh cat\n</text>")
        self.assertEqual(self.captured["body"]["system"], "fix it")

    def test_timeout_is_honoured(self):
        self.call(timeoutSec=7)
        self.assertEqual(self.captured["timeout"], 7)

    def test_max_tokens_grows_with_the_selection(self):
        """Thinking tokens count against max_tokens, so a fixed cap truncates."""
        self.assertEqual(self.mod.estimate_max_tokens("short"), 4096)
        big = self.mod.estimate_max_tokens("x" * 40000)
        self.assertGreater(big, 4096)
        self.assertLessEqual(big, 32000)
        self.assertEqual(self.mod.estimate_max_tokens("x" * 10_000_000), 32000)

    # ------------------------------------------------------ response shape

    def test_text_blocks_are_joined(self):
        self.reply["content"] = [{"type": "text", "text": "the "}, {"type": "text", "text": "cat"}]
        self.assertEqual(self.mod.extract(self.reply), "the cat")

    def test_thinking_blocks_are_skipped(self):
        """Thinking shares the content array and is empty by default."""
        self.reply["content"] = [
            {"type": "thinking", "thinking": ""},
            {"type": "text", "text": "the cat"},
        ]
        self.assertEqual(self.mod.extract(self.reply), "the cat")

    def test_a_refusal_is_an_error_not_empty_text(self):
        self.reply["stop_reason"] = "refusal"
        self.reply["stop_details"] = {"type": "refusal", "category": "cyber"}
        self.reply["content"] = []
        with self.assertRaises(SystemExit) as caught:
            self.mod.extract(self.reply)
        self.assertEqual(caught.exception.code, 3)

    def test_truncation_is_an_error(self):
        """A half-finished correction silently replacing the clipboard is worse
        than a visible failure."""
        self.reply["stop_reason"] = "max_tokens"
        with self.assertRaises(SystemExit) as caught:
            self.mod.extract(self.reply)
        self.assertEqual(caught.exception.code, 3)

    def test_a_401_is_a_config_error(self):
        def unauthorized(request, timeout=None):
            raise urllib.error.HTTPError(
                request.full_url, 401, "Unauthorized", {},
                io.BytesIO(json.dumps({"error": {"message": "invalid x-api-key"}}).encode()))

        self.mod.urllib.request.urlopen = unauthorized
        with self.assertRaises(SystemExit) as caught:
            self.call()
        self.assertEqual(caught.exception.code, 2)

    def test_a_529_is_an_upstream_error(self):
        def overloaded(request, timeout=None):
            raise urllib.error.HTTPError(request.full_url, 529, "Overloaded", {}, io.BytesIO(b"{}"))

        self.mod.urllib.request.urlopen = overloaded
        with self.assertRaises(SystemExit) as caught:
            self.call()
        self.assertEqual(caught.exception.code, 3)

    # ------------------------------------------------------- key resolution

    def test_the_environment_wins_over_the_keyring(self):
        os.environ["ANTHROPIC_API_KEY"] = "sk-from-env"
        try:
            self.assertEqual(self.mod.resolve_key(), "sk-from-env")
        finally:
            del os.environ["ANTHROPIC_API_KEY"]

    def test_the_key_help_names_the_command_to_run(self):
        self.assertIn("secret-tool store", self.mod.KEY_HELP)
        self.assertIn("ANTHROPIC_API_KEY", self.mod.KEY_HELP)


class OpenAiAdapter(unittest.TestCase):
    def setUp(self):
        self.mod = load("openai")
        self.captured = {}

        def fake_urlopen(request, timeout=None):
            self.captured["url"] = request.full_url
            self.captured["headers"] = {k.lower(): v for k, v in request.headers.items()}
            self.captured["body"] = json.loads(request.data.decode("utf-8"))
            return FakeResponse(json.dumps(self.reply).encode("utf-8"))

        self.mod.urllib.request.urlopen = fake_urlopen
        self.reply = {
            "model": "llama3.2",
            "choices": [{"finish_reason": "stop", "message": {"content": "the cat"}}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 9},
        }
        for key in ("SCRIBE_OPENAI_BASE_URL", "OPENAI_BASE_URL"):
            os.environ.pop(key, None)
        # A key so the request-shape tests get past the credential gate; the
        # transport is faked, so it is never sent anywhere.
        self.saved_key = os.environ.get("SCRIBE_OPENAI_API_KEY")
        os.environ["SCRIBE_OPENAI_API_KEY"] = "sk-test"

    def tearDown(self):
        if self.saved_key is None:
            os.environ.pop("SCRIBE_OPENAI_API_KEY", None)
        else:
            os.environ["SCRIBE_OPENAI_API_KEY"] = self.saved_key

    def test_default_endpoint(self):
        self.assertEqual(self.mod.base_url(), "https://api.openai.com/v1")

    def test_base_url_override(self):
        os.environ["SCRIBE_OPENAI_BASE_URL"] = "http://localhost:11434/v1/"
        try:
            self.assertEqual(self.mod.base_url(), "http://localhost:11434/v1")
        finally:
            del os.environ["SCRIBE_OPENAI_BASE_URL"]

    def test_the_option_beats_the_environment(self):
        """The panel setting is the authority; the env var is the fallback."""
        os.environ["SCRIBE_OPENAI_BASE_URL"] = "http://from-env:1234/v1"
        try:
            self.assertEqual(
                self.mod.base_url({"baseUrl": "http://from-setting:11434/v1/"}),
                "http://from-setting:11434/v1")
            self.assertEqual(self.mod.base_url({}), "http://from-env:1234/v1")
            self.assertEqual(self.mod.base_url({"baseUrl": "  "}), "http://from-env:1234/v1")
        finally:
            del os.environ["SCRIBE_OPENAI_BASE_URL"]

    def test_only_openai_itself_demands_a_key_up_front(self):
        """A remote ollama has no auth; demanding a key would make the
        common case impossible."""
        self.assertTrue(self.mod.needs_key("https://api.openai.com/v1"))
        self.assertFalse(self.mod.needs_key("http://gpu-box.local:11434/v1"))
        self.assertFalse(self.mod.needs_key("http://192.168.1.20:11434/v1"))
        self.assertFalse(self.mod.needs_key("http://localhost:11434/v1"))

    def test_a_remote_endpoint_is_used_for_the_request(self):
        result = self.run_main(options={"baseUrl": "http://gpu-box.local:11434/v1"})
        self.assertEqual(self.captured["url"],
                         "http://gpu-box.local:11434/v1/chat/completions")
        self.assertEqual(result["text"], "the cat")

    def test_a_leading_think_block_is_stripped(self):
        """qwen3 and deepseek-r1 narrate into the content; the clipboard must
        get the correction, not the narration."""
        self.reply["choices"][0]["message"]["content"] = (
            "<think>\nThe user wrote teh, that is a typo.\n</think>\nthe cat")
        self.assertEqual(self.run_main()["text"], "the cat")

    def test_think_tags_inside_the_text_are_left_alone(self):
        """Someone proofreading a blog post about reasoning models must not
        have their own prose eaten."""
        prose = "I like the <think> tag idea."
        self.reply["choices"][0]["message"]["content"] = prose
        self.assertEqual(self.run_main()["text"], prose)

    def test_an_unclosed_think_block_is_left_alone(self):
        text = "<think> never closed, so this is just text"
        self.reply["choices"][0]["message"]["content"] = text
        self.assertEqual(self.run_main()["text"], text)

    def test_localhost_needs_no_key(self):
        """ollama and llama.cpp do not have one to give."""
        for url in ("http://localhost:11434/v1", "http://127.0.0.1:8080/v1", "http://box.local/v1"):
            self.assertTrue(self.mod.is_local(url), url)
        self.assertFalse(self.mod.is_local("https://api.openai.com/v1"))

    def run_main(self, options=None):
        """Drive the adapter's main() with a payload on a fake stdin."""
        payload = {"system": "fix it", "text": "teh cat", "model": "llama3.2",
                   "timeoutSec": 30, "options": options or {}}
        stdin, argv, stdout = sys.stdin, sys.argv, sys.stdout
        sys.stdin = io.StringIO(json.dumps(payload))
        sys.argv = ["openai"]
        sys.stdout = io.StringIO()
        try:
            self.mod.main()
            return json.loads(sys.stdout.getvalue())
        finally:
            sys.stdin, sys.argv, sys.stdout = stdin, argv, stdout

    def test_finish_reason_length_is_an_error(self):
        self.reply["choices"][0]["finish_reason"] = "length"
        with self.assertRaises(SystemExit) as caught:
            self.run_main()
        self.assertEqual(caught.exception.code, 3)

    def test_the_selection_is_tagged(self):
        self.run_main()
        messages = self.captured["body"]["messages"]
        self.assertEqual(messages[0]["role"], "system")
        self.assertEqual(messages[0]["content"], "fix it")
        self.assertEqual(messages[1]["content"], "<text>\nteh cat\n</text>")

    def test_usage_is_translated_to_the_contract_names(self):
        result = self.run_main()
        self.assertEqual(result["usage"], {"input_tokens": 12, "output_tokens": 9})
        self.assertEqual(result["text"], "the cat")


class ClaudeCliAdapter(unittest.TestCase):
    def test_missing_binary_is_a_config_error(self):
        emptybin = tempfile.mkdtemp(prefix="scribe-nobin-")
        try:
            result = subprocess.run(
                [sys.executable, os.path.join(BACKEND_DIR, "claude-cli"), "--check"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20,
                env={**os.environ, "PATH": emptybin},
            )
        finally:
            os.rmdir(emptybin)
        self.assertEqual(result.returncode, 2)
        self.assertIn("claude", result.stderr)


class ProfilesShipped(unittest.TestCase):
    """The prompts are the product; a regression here is silent."""

    def setUp(self):
        spec = importlib.util.spec_from_loader(
            "scribe_cli",
            importlib.machinery.SourceFileLoader("scribe_cli", os.path.join(PLUGIN_DIR, "scribe")),
        )
        self.cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cli)

    def test_every_profile_forbids_a_preamble(self):
        for profile in self.cli.BUILTIN_PROFILES["profiles"]:
            with self.subTest(profile=profile["name"]):
                self.assertIn("nothing else", profile["system"])

    def test_every_profile_preserves_the_language(self):
        """German text has to come back German."""
        for profile in self.cli.BUILTIN_PROFILES["profiles"]:
            with self.subTest(profile=profile["name"]):
                self.assertIn("original language", profile["system"])

    def test_every_profile_guards_against_injection(self):
        for profile in self.cli.BUILTIN_PROFILES["profiles"]:
            with self.subTest(profile=profile["name"]):
                self.assertIn("<text>", profile["system"])
                self.assertIn("Never", profile["system"])

    def test_unwrap_leaves_ordinary_text_alone(self):
        self.assertEqual(self.cli.unwrap("the cat", "teh cat"), "the cat")
        self.assertEqual(self.cli.unwrap("a\nb", "x\ny"), "a\nb")


if __name__ == "__main__":
    unittest.main(verbosity=0, buffer=True)
