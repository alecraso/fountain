"""scripts/precommit-tests.py's selection, against a fake tree.

The rules under test: a changed test file is itself; a changed lib file is
its mirror test plus every same-stem test in that app's tree (ee/lib looks
in ee/test and apps/fountain/test); a docs change is the manual's tests; a
file every test reads escalates to the whole suite; a lib file with no
test is reported, not silently dropped; ee tests are reached from
apps/fountain as ../../ee/test.
"""

import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("precommit_tests", ROOT / "scripts" / "precommit-tests.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeTree:
    def __init__(self, files):
        self.files = set(files)

    def exists(self, path):
        return path in self.files

    def glob(self, base, pattern):
        # `**/` in the script's patterns means any depth under base.
        suffix = pattern.split("**/")[-1]
        matcher = pathlib.PurePosixPath("x/" + suffix)
        return sorted(
            f for f in self.files
            if f.startswith(base + "/") and pathlib.PurePosixPath("x/" + f.rsplit("/", 1)[-1]).match(matcher.as_posix())
        )


TREE = FakeTree([
    "apps/fountain/test/fountain/search_test.exs",
    "apps/fountain/test/fountain_web/controllers/search_controller_test.exs",
    "apps/fountain/test/fountain/brand_test.exs",
    "apps/fountain/test/fountain/docs_test.exs",
    "apps/fountain/test/fountain_web/controllers/docs_controller_test.exs",
    "ee/test/fountain/workers/welcome_email_test.exs",
    "ee/test/fountain/credits_test.exs",
    "apps/fountain/test/fountain/credits_billing_off_test.exs",
    "apps/fountain_buzz/test/fountain_buzz/harness_test.exs",
    "apps/fountain_buzz/test/fountain_buzz/harness_sweep_test.exs",
    "apps/fountain_buzz/test/fountain_buzz/docs_test.exs",
    "apps/fountain_buzz/test/fountain_buzz/manual_test.exs",
])


class Selection(unittest.TestCase):
    def select(self, *changed):
        return module.select(list(changed), TREE)

    def test_a_changed_test_file_is_itself(self):
        sel = self.select("apps/fountain/test/fountain/brand_test.exs", "ee/test/fountain/credits_test.exs")
        self.assertEqual(sel.tests, ["apps/fountain/test/fountain/brand_test.exs", "ee/test/fountain/credits_test.exs"])
        self.assertIsNone(sel.full_reason)

    def test_a_lib_file_selects_its_mirror_and_same_stem_tests(self):
        sel = self.select("apps/fountain/lib/fountain/search.ex")
        self.assertEqual(sel.tests, [
            "apps/fountain/test/fountain/search_test.exs",
            "apps/fountain/test/fountain_web/controllers/search_controller_test.exs",
        ])

    def test_an_ee_lib_file_looks_in_ee_test_and_the_core_tree(self):
        sel = self.select("ee/lib/fountain/credits.ex")
        self.assertEqual(sel.tests, [
            "ee/test/fountain/credits_test.exs",
            "apps/fountain/test/fountain/credits_billing_off_test.exs",
        ])

    def test_a_template_maps_like_its_module(self):
        sel = self.select("apps/fountain_buzz/lib/fountain_buzz/harness.html.heex")
        self.assertEqual(sel.tests, [
            "apps/fountain_buzz/test/fountain_buzz/harness_test.exs",
            "apps/fountain_buzz/test/fountain_buzz/harness_sweep_test.exs",
        ])

    def test_a_docs_change_selects_the_manual_tests_that_exist(self):
        sel = self.select("docs/setup.md")
        self.assertEqual(sel.tests, [
            "apps/fountain/test/fountain/docs_test.exs",
            "apps/fountain/test/fountain_web/controllers/docs_controller_test.exs",
            "apps/fountain_buzz/test/fountain_buzz/docs_test.exs",
            "apps/fountain_buzz/test/fountain_buzz/manual_test.exs",
        ])

    def test_a_file_every_test_reads_escalates_to_the_whole_suite(self):
        for path in [
            "mix.lock", "config/test.exs", "apps/fountain/mix.exs", "coverage.exs",
            "apps/fountain/test/support/factory.ex", "apps/fountain_buzz/test/test_helper.exs",
            "apps/fountain/priv/repo/migrations/20260914120000_x.exs",
            "apps/fountain_buzz/priv/repo/migrations/20260914120000_x.exs",
        ]:
            with self.subTest(path=path):
                sel = self.select("apps/fountain/lib/fountain/search.ex", path)
                self.assertEqual(sel.full_reason, path)

    def test_a_lib_file_with_no_test_is_reported_not_dropped(self):
        sel = self.select("apps/fountain/lib/fountain_web/router.ex")
        self.assertEqual(sel.tests, [])
        self.assertEqual(sel.unmatched, ["apps/fountain/lib/fountain_web/router.ex"])

    def test_non_elixir_paths_select_nothing_and_are_listed(self):
        sel = self.select("scripts/precommit.sh", "CLAUDE.md", ".github/workflows/ci.yml")
        self.assertEqual(sel.tests, [])
        self.assertEqual(sel.ignored, ["scripts/precommit.sh", "CLAUDE.md", ".github/workflows/ci.yml"])

    def test_invocations_group_per_app_and_reach_ee_from_apps_fountain(self):
        groups = module.invocations([
            "apps/fountain/test/fountain/search_test.exs",
            "ee/test/fountain/credits_test.exs",
            "apps/fountain_buzz/test/fountain_buzz/harness_test.exs",
        ])
        self.assertEqual(groups, {
            "apps/fountain": ["test/fountain/search_test.exs", "../../ee/test/fountain/credits_test.exs"],
            "apps/fountain_buzz": ["test/fountain_buzz/harness_test.exs"],
        })

    def test_the_docs_tests_it_mirrors_exist_in_this_repo(self):
        # scripts/test-docs.sh names the same files; both lists drift if only one moves.
        for t in module.DOCS_TESTS:
            self.assertTrue((ROOT / t).is_file(), t)


if __name__ == "__main__":
    unittest.main()
