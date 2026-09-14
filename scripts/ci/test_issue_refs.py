"""scripts/ci/check_issue_refs.py: the regex, the diff walk, the rule, the comment.

The fixture diff is a slice of #1008's, the PR that shipped `#1006` (an
unrelated open PR at the time) in 20 places. The validation the issue asked
for is `test_the_1008_diff_flags_1006`.
"""

import argparse
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_issue_refs as refs  # noqa: E402

PR_1008 = """\
diff --git a/apps/fountain/lib/fountain/docs.ex b/apps/fountain/lib/fountain/docs.ex
index 1111111..2222222 100644
--- a/apps/fountain/lib/fountain/docs.ex
+++ b/apps/fountain/lib/fountain/docs.ex
@@ -7,6 +7,9 @@ defmodule Fountain.Docs do
   It used to be built as a MkDocs Material site as well; that copy was
-  retired, so there is no `mkdocs.yml` to keep green.
+  retired in #1006, so there is no `mkdocs.yml` and no `docs.yml` workflow
+  to keep green. A page reaches a reader through `/docs` or not at all.
+  Heading ids come from MDEx (#765).
diff --git a/CHANGELOG.md b/CHANGELOG.md
--- a/CHANGELOG.md
+++ b/CHANGELOG.md
@@ -52,3 +52,4 @@
 ### Removed
+- The MkDocs site and its GitHub Pages deploy (#1006).
"""

TRAPS = """\
--- a/assets/app.css
+++ b/assets/app.css
@@ -1,2 +1,2 @@
+.x { color: #111827; background: #666; border-color: #123 }
--- a/apps/fountain/test/markdown_test.exs
+++ b/apps/fountain/test/markdown_test.exs
@@ -1,4 +1,8 @@
+  assert "&#106;avascript:" == escaped
+  assert "&#115;" in body
+  # entity #106 was the XSS vector, fixed in #106
+  color = "#111827" <> "#000" <> "#0123"
+  style = "background: #666; color: #123"
+  see https://github.com/managoat/fountain/pull/540 and github.com/other/repo/issues/9
+  a#12 anchor, ##3 heading, (#1013), #2000.
-  removed line cites #999
"""


def item(state, title, kind):
    return {"state": state, "title": title, "kind": kind}


class CitationTest(unittest.TestCase):
    def test_added_lines_only_with_new_file_line_numbers(self):
        self.assertEqual(list(refs.citations(PR_1008)), [
            ("apps/fountain/lib/fountain/docs.ex", 8, 1006),
            ("apps/fountain/lib/fountain/docs.ex", 10, 765),
            ("CHANGELOG.md", 53, 1006),
        ])

    def test_colours_entities_words_and_other_repos_do_not_match(self):
        found = refs.collect(TRAPS, cap=2173)
        # Stylesheets are skipped, `#666;` and `#0123` are not citations,
        # `&#106;` and `&#115;` are entities, `#111827` is over the cap, and
        # only this repository's URLs count.
        self.assertEqual(set(found), {106, 123, 540, 1013, 2000})
        self.assertEqual(found[106], ["apps/fountain/test/markdown_test.exs:3"])
        self.assertEqual(found[540], ["apps/fountain/test/markdown_test.exs:6"])
        self.assertNotIn(999, found, "a removed line is not a new citation")

    def test_the_cap_drops_six_digit_colours_but_keeps_the_newest_number(self):
        diff = "--- a/x.md\n+++ b/x.md\n@@ -1 +1,2 @@\n+#2173 and #111827\n+#2174\n"
        self.assertEqual(list(refs.collect(diff, cap=2173)), [2173])

    def test_a_deleted_file_adds_nothing(self):
        diff = "--- a/x.md\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-cited #12\n"
        self.assertEqual(list(refs.citations(diff)), [])


class ResolveTest(unittest.TestCase):
    @patch("check_issue_refs.api")
    def test_state_distinguishes_merged_closed_open_and_missing(self, api):
        api.side_effect = [
            {"state": "closed", "title": "Merged", "pull_request": {"merged_at": "2026-08-23"}},
            {"state": "closed", "title": "Abandoned", "pull_request": {"merged_at": None}},
            {"state": "open", "title": "Issue"},
            HTTPError("url", 404, "Not Found", {}, None),
        ]
        self.assertEqual(refs.resolve("o/r", 1)["state"], "MERGED")
        self.assertEqual(refs.resolve("o/r", 2), item("CLOSED", "Abandoned", "pull request"))
        self.assertEqual(refs.resolve("o/r", 3), item("OPEN", "Issue", "issue"))
        self.assertEqual(refs.resolve("o/r", 4)["state"], "MISSING")

    @patch("check_issue_refs.api")
    def test_other_api_failures_propagate(self, api):
        api.side_effect = HTTPError("url", 500, "Server Error", {}, None)
        with self.assertRaises(HTTPError):
            refs.resolve("o/r", 1)

    @patch("check_issue_refs.api")
    def test_highest_number_is_the_newest_issue_or_pr(self, api):
        api.return_value = [{"number": 2173}]
        self.assertEqual(refs.highest_number("o/r"), 2173)
        self.assertIn("sort=created&direction=desc", api.call_args.args[1])

    @patch.dict(os.environ, {"GH_TOKEN": "t0k3n"})
    @patch("check_issue_refs.urlopen")
    def test_the_token_is_a_bearer_header_and_bodies_are_json(self, urlopen):
        urlopen.return_value.__enter__.return_value = io.StringIO('{"ok": true}')
        refs.api("POST", "/repos/o/r/issues/1/comments", {"body": "hi"})
        request = urlopen.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer t0k3n")
        self.assertEqual(request.data, b'{"body": "hi"}')
        self.assertEqual(request.get_method(), "POST")


class ReportTest(unittest.TestCase):
    def resolved(self):
        return {
            765: item("CLOSED", "Docs: heading ids", "issue"),
            1006: item("OPEN", "ci(sdk): make CI the only publisher", "pull request"),
        }

    def test_render_marks_the_open_one_and_carries_the_marker(self):
        found = refs.collect(PR_1008, cap=1013)
        body = refs.render(found, self.resolved())
        self.assertTrue(body.startswith(refs.MARKER))
        self.assertIn("- #765 → **CLOSED** Docs: heading ids (issue)\n", body)
        self.assertIn("- #1006 → **OPEN** ci(sdk): make CI the only publisher (pull request) :warning:", body)
        self.assertIn("`apps/fountain/lib/fountain/docs.ex:8`, `CHANGELOG.md:53`", body)

    def test_render_truncates_long_location_lists(self):
        found = {5: [f"f{i}.md:1" for i in range(7)]}
        body = refs.render(found, {5: item("MERGED", "t", "pull request")})
        self.assertIn("`f2.md:1`, +4 more", body)
        self.assertNotIn("f3.md", body)

    def test_render_with_nothing_found_still_carries_the_marker(self):
        self.assertIn("no new issue or PR citations", refs.render({}, {}))
        self.assertTrue(refs.render({}, {}).startswith(refs.MARKER))


class CommentTest(unittest.TestCase):
    @patch("check_issue_refs.api")
    def test_a_second_run_updates_the_marked_comment_instead_of_adding_one(self, api):
        api.side_effect = [[{"id": 7, "body": "unrelated"}, {"id": 9, "body": refs.MARKER + "\nold"}], {}]
        self.assertEqual(refs.upsert_comment("o/r", 3, "new"), "updated")
        method, path, body = api.call_args.args
        self.assertEqual((method, path, body), ("PATCH", "/repos/o/r/issues/comments/9", {"body": "new"}))

    @patch("check_issue_refs.api")
    def test_the_first_run_creates_the_comment(self, api):
        api.side_effect = [[{"id": 7, "body": "unrelated"}], {}]
        self.assertEqual(refs.upsert_comment("o/r", 3, "new"), "created")
        self.assertEqual(api.call_args.args[:2], ("POST", "/repos/o/r/issues/3/comments"))


class MainTest(unittest.TestCase):
    """The CLI end to end, with the API mocked at the one seam."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.diff = Path(self.temp.name) / "pr.diff"
        self.diff.write_text(PR_1008)
        self.calls = []

    def fake_api(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path.startswith("/repos/managoat/fountain/issues?"):
            return [{"number": 1013}]
        if path.endswith("/issues/1006"):
            return {"state": "open", "title": "ci(sdk): make CI the only publisher",
                    "pull_request": {"merged_at": None}}
        if path.endswith("/issues/765"):
            return {"state": "closed", "title": "Docs: heading ids"}
        if path.endswith("/comments?per_page=100"):
            return []
        if method == "POST":
            return {}
        raise AssertionError(f"unexpected call {method} {path}")

    def run_main(self, *args, api=None):
        out, err = io.StringIO(), io.StringIO()
        with patch("check_issue_refs.api", side_effect=api or self.fake_api), \
                patch("sys.stdout", out), patch("sys.stderr", err):
            code = refs.main(["--diff", str(self.diff), "--repo", "managoat/fountain", *args])
        return code, out.getvalue(), err.getvalue()

    def test_the_1008_diff_flags_1006(self):
        code, out, err = self.run_main()
        self.assertEqual(code, 0, "stage 1 comments and does not gate")
        self.assertIn("#1006 -> [OPEN] ci(sdk): make CI the only publisher", out)
        self.assertIn("apps/fountain/lib/fountain/docs.ex:8, CHANGELOG.md:53", out)
        self.assertIn("#765 -> [CLOSED] Docs: heading ids", out)
        self.assertIn("Checked 2 new citations (numbers up to #1013); 1 open or missing", out)
        self.assertEqual(err, "")

    def test_strict_fails_on_the_open_citation_and_names_it(self):
        code, _, err = self.run_main("--strict")
        self.assertEqual(code, 1)
        self.assertIn("::error::#1006 is OPEN", err)
        self.assertNotIn("#765", err)

    def test_strict_passes_once_everything_is_closed(self):
        code, _, err = self.run_main("--strict", "--max", "1000")
        self.assertEqual(code, 0, "#1006 is over the cap, #765 is closed")
        self.assertEqual(err, "")

    def test_comment_posts_once_and_writes_the_step_summary(self):
        summary = Path(self.temp.name) / "summary.md"
        with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
            code, out, _ = self.run_main("--comment", "--pr", "1008")
        self.assertEqual(code, 0)
        self.assertIn("Comment created on #1008", out)
        posts = [c for c in self.calls if c[0] == "POST"]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0][1], "/repos/managoat/fountain/issues/1008/comments")
        self.assertIn("#1006 → **OPEN**", posts[0][2]["body"])
        self.assertTrue(summary.read_text().startswith(refs.MARKER))

    def test_a_clean_pr_gets_no_comment(self):
        self.diff.write_text("--- a/x.md\n+++ b/x.md\n@@ -1 +1 @@\n+no citations here\n")
        code, out, _ = self.run_main("--comment", "--pr", "1008")
        self.assertEqual(code, 0)
        self.assertNotIn("Comment", out)
        self.assertEqual([c for c in self.calls if c[0] == "POST"], [])

    def test_a_read_only_token_cannot_block_the_step(self):
        def forbidden(method, path, body=None):
            if method == "POST":
                raise HTTPError("url", 403, "Forbidden", {}, None)
            return self.fake_api(method, path, body)

        code, _, err = self.run_main("--comment", "--pr", "1008", api=forbidden)
        self.assertEqual(code, 0)
        self.assertIn("::warning::could not comment on #1008", err)

    def test_comment_without_pr_is_a_usage_failure(self):
        code, _, err = self.run_main("--comment")
        self.assertEqual(code, 2)
        self.assertIn("--comment needs --pr", err)

    def test_an_api_outage_is_a_tooling_failure_not_a_verdict(self):
        out, err = io.StringIO(), io.StringIO()
        with patch("check_issue_refs.api", side_effect=HTTPError("url", 503, "Down", {}, None)), \
                patch("sys.stdout", out), patch("sys.stderr", err):
            code = refs.main(["--diff", str(self.diff)])
        self.assertEqual(code, 2)
        self.assertIn("::error::check_issue_refs could not resolve", err.getvalue())
        self.assertEqual(out.getvalue(), "")


class GitDiffTest(unittest.TestCase):
    def test_reads_the_diff_from_git_when_given_a_base(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def git(*args):
                subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@x", *args],
                               cwd=root, check=True, capture_output=True)

            git("init", "--quiet")
            git("commit", "--allow-empty", "-qm", "root")
            (root / "notes.md").write_text("see #765 and #111827\n")
            git("add", "notes.md")
            git("commit", "-qm", "cite")
            cwd = os.getcwd()
            os.chdir(root)
            try:
                diff = refs.read_diff(argparse.Namespace(diff=None, base="HEAD~1", head="HEAD"))
            finally:
                os.chdir(cwd)
        self.assertEqual(refs.collect(diff, cap=1013), {765: ["notes.md:1"]})

    def test_neither_base_nor_diff_is_a_usage_error(self):
        with self.assertRaises(SystemExit):
            refs.read_diff(argparse.Namespace(diff=None, base=None, head="HEAD"))


if __name__ == "__main__":
    unittest.main()
