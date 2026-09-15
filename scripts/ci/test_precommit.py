"""scripts/precommit.sh's argument handling and verdict, without a toolchain.

The gate's promise is that its exit status is the verdict. These tests pin
the two ways that promise was found breakable in review of the first cut:
a stage name read as a regular expression (`te.t`, `.*`, `test$`) passed
validation, selected nothing and printed PASSED over zero stages; and a
subset must run in the canonical order and stop, with the failing stage's
status, at the first failure.

A stub `mix` on PATH records what it was asked to run, so no Elixir is
needed. Stages that shell out to anything else (toolchain, conflict-markers,
sobelow) are not selected here. The default test stage is
scripts/precommit-tests.py, which reads PRECOMMIT_CHANGED_FILES here instead
of git so the selection is fixed; the selection rules themselves are
test_precommit_tests.py.
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
        # The default test stage selects against this list, not git.
        self.changed = pathlib.Path(self.tmp.name) / "changed.txt"
        self.changed.write_text("apps/fountain/test/fountain/brand_test.exs\n")
        self.env["PRECOMMIT_CHANGED_FILES"] = str(self.changed)

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
            [
                "test compile --warnings-as-errors",
                "test credo --strict",
                "test test test/fountain/brand_test.exs",
            ],
        )
        self.assertIn("precommit: PASSED (3 stages", result.stdout)

    def test_the_test_stage_runs_the_changed_files_tests_and_the_suite_with_full(self):
        result = self.run_script("test")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mix_calls(), ["test test test/fountain/brand_test.exs"])
        self.assertIn("precommit-tests: apps/fountain: mix test test/fountain/brand_test.exs", result.stdout)

        self.log.unlink()
        self.changed.write_text("scripts/precommit.sh\n")
        result = self.run_script("test")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mix_calls(), [])
        self.assertIn("0 test files selected", result.stdout)
        self.assertIn("precommit: PASSED (1 stages", result.stdout)

        self.changed.write_text("mix.lock\n")
        result = self.run_script("test")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mix_calls(), ["test test"])
        self.assertIn("mix.lock is an input to every test", result.stdout)
        self.log.unlink()

        for args in [("--full", "test"), ("test", "--full"), ("--full", "credo", "test")]:
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.mix_calls()[-1], "test test")
                self.assertNotIn("precommit-tests:", result.stdout)
                self.log.unlink()

    def test_list_says_what_the_test_stage_runs_in_each_mode(self):
        result = self.run_script("--list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[--full]", result.stdout)
        test_line = next(line for line in result.stdout.splitlines() if line.startswith("  test "))
        self.assertIn("scripts/precommit-tests.py", test_line)
        self.assertIn("--full", test_line)

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
