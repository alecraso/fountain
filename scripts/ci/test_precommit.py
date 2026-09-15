"""scripts/precommit.sh's argument handling and verdict, without a toolchain.

The gate's promise is that its exit status is the verdict. These tests pin
the two ways that promise was found breakable in review of the first cut:
a stage name read as a regular expression (`te.t`, `.*`, `test$`) passed
validation, selected nothing and printed PASSED over zero stages; and a
subset must run in the canonical order and stop, with the failing stage's
status, at the first failure.

A stub `mix` on PATH records what it was asked to run, so no Elixir is
needed. Stages that shell out to anything else (toolchain, conflict-markers,
sobelow) are not selected here.
"""

import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "precommit.sh"

STAGES = [
    "toolchain",
    "conflict-markers",
    "compile",
    "deps",
    "format",
    "credo",
    "dialyzer",
    "sobelow",
    "release",
    "test",
]

STUB_MIX = """#!/bin/sh
echo "${MIX_ENV:-unset} $*" >> "$PRECOMMIT_TEST_LOG"
case "$*" in
  *credo*) exit "${PRECOMMIT_TEST_FAIL_CREDO:-0}" ;;
esac
exit 0
"""


class PrecommitScript(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        bin_dir = pathlib.Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "mix"
        stub.write_text(STUB_MIX)
        stub.chmod(0o755)
        self.log = pathlib.Path(self.tmp.name) / "mix.log"
        self.env = dict(
            os.environ,
            PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            PRECOMMIT_TEST_LOG=str(self.log),
        )
        self.env.pop("PRECOMMIT_TEST_FAIL_CREDO", None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args, **env):
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=ROOT,
            env={**self.env, **env},
            capture_output=True,
            text=True,
            check=False,
        )

    def mix_calls(self):
        if not self.log.exists():
            return []
        return self.log.read_text().splitlines()

    def test_list_names_every_stage_in_order(self):
        result = self.run_script("--list")
        self.assertEqual(result.returncode, 0, result.stderr)
        listed = [line.split()[0] for line in result.stdout.splitlines() if line.startswith("  ")]
        self.assertEqual(listed, STAGES)
        self.assertEqual(self.mix_calls(), [])

    def test_a_pattern_shaped_name_is_rejected_and_never_passes(self):
        for name in ["te.t", ".*", "test$", "^credo", "[t]est"]:
            with self.subTest(name=name):
                result = self.run_script(name)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertIn(f"no stage named '{name}'", result.stderr)
                self.assertNotIn("PASSED", result.stdout)
                self.assertEqual(self.mix_calls(), [])

    def test_an_unknown_name_and_an_unknown_option_exit_64(self):
        for arg in ["nope", "--nope"]:
            with self.subTest(arg=arg):
                result = self.run_script(arg)
                self.assertEqual(result.returncode, 64)
                self.assertNotIn("PASSED", result.stdout)

    def test_a_subset_runs_in_canonical_order_whatever_the_argument_order(self):
        result = self.run_script("test", "credo", "compile")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.mix_calls(),
            ["test compile --warnings-as-errors", "test credo --strict", "test test"],
        )
        self.assertIn("precommit: PASSED (3 stages", result.stdout)

    def test_a_failing_stage_stops_the_run_with_its_own_status(self):
        result = self.run_script("compile", "credo", "test", PRECOMMIT_TEST_FAIL_CREDO="23")
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertEqual(
            self.mix_calls(),
            ["test compile --warnings-as-errors", "test credo --strict"],
        )
        self.assertIn("credo FAILED (exit 23", result.stdout)
        self.assertIn("not run: test", result.stdout)
        self.assertIn("precommit: FAILED at credo (exit 23)", result.stdout)
        self.assertNotIn("PASSED", result.stdout)

    def test_each_stage_names_its_env(self):
        result = self.run_script("dialyzer", "release")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.mix_calls(),
            ["dev dialyzer", "prod deps.get", "prod release fountain_server --overwrite"],
        )


if __name__ == "__main__":
    unittest.main()
