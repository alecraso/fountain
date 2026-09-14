"""scripts/changelog.py: fragments in, a release section out, and the guard.

The real CHANGELOG.md is one of the fixtures: the release roll has to be
able to parse whatever `[Unreleased]` holds on main, so a hand edit that
breaks the shape fails here rather than on release day.
"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "changelog.py"
sys.path.insert(0, str(SCRIPT.parent))
import changelog  # noqa: E402

PREAMBLE = "# Changelog\n\nSome preamble.\n\n---\n\n## [Unreleased]\n"
RELEASED = "## [0.16.0] - 2026-09-03\n\n### Fixed\n\n- Old fix (#1).\n"


def write(root: Path, name: str, text: str) -> Path:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "changelog.d").mkdir()
        write(self.root, "changelog.d/README.md", "# not a fragment\n")

    def run_script(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), *args],
            capture_output=True, text=True,
        )

    def changelog(self, unreleased_body: str = "\n" + changelog.UNRELEASED_STUB + "\n"):
        return write(self.root, "CHANGELOG.md", PREAMBLE + unreleased_body + RELEASED)


class FragmentTest(Fixture):
    def test_a_fragment_uses_the_changelog_headings(self):
        write(self.root, "changelog.d/2105-retired-urls.md",
              "### Upgrade notes\n\n- Retired URLs 404 (#2105).\n\n### Fixed\n\n- A fix.\n")
        sections = changelog.read_fragments(self.root)
        self.assertEqual(sections["Upgrade notes"], ["- Retired URLs 404 (#2105)."])
        self.assertEqual(sections["Fixed"], ["- A fix."])

    def test_readme_and_dotfiles_are_not_fragments(self):
        write(self.root, "changelog.d/.gitkeep", "")
        self.assertEqual(changelog.fragment_paths(self.root), [])

    def test_check_names_the_bad_fragment(self):
        self.changelog()
        cases = {
            "unknown section": "### Breaking\n\n- x\n",
            "text before the first": "- x\n",
            "has no `- ` bullet": "### Fixed\n\nprose only\n",
            "release heading": "## [0.17.0]\n\n### Fixed\n\n- x\n",
            "no `### Section` heading": "\n",
        }
        for message, text in cases.items():
            with self.subTest(message=message):
                path = write(self.root, "changelog.d/bad.md", text)
                result = self.run_script("check")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("changelog.d/bad.md", result.stderr)
                self.assertIn(message, result.stderr)
                path.unlink()

    def test_check_counts_entries(self):
        self.changelog()
        write(self.root, "changelog.d/a.md", "### Added\n\n- one\n- two\n")
        write(self.root, "changelog.d/b.md", "### Fixed\n\n- three\n")
        result = self.run_script("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 fragment(s), 3 entries", result.stdout)

    def test_check_also_parses_unreleased(self):
        # A hand edit that puts prose under [Unreleased] would stop the roll.
        self.changelog("\nSome prose with no section.\n\n")
        result = self.run_script("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("CHANGELOG.md [Unreleased]", result.stderr)


class NormalizeTest(Fixture):
    def test_folds_repeated_headings_and_orders_sections(self):
        self.changelog(
            "\n### Fixed\n\n- f1\n\n### Added\n\n- a1\n\n### Fixed\n\n- f2\n\n"
            "### Upgrade notes\n\n- u1\n\n"
        )
        result = self.run_script("normalize")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.root / "CHANGELOG.md").read_text()
        _, body, rest = changelog.split_changelog(text)
        self.assertEqual(
            body,
            "\n### Upgrade notes\n\n- u1\n\n### Added\n\n- a1\n\n### Fixed\n\n- f1\n\n- f2\n\n",
        )
        self.assertEqual(rest, RELEASED)
        self.assertEqual(changelog.normalize_text(text), text, "idempotent")

    def test_an_empty_unreleased_becomes_the_stub(self):
        self.changelog("\n\n")
        self.run_script("normalize")
        _, body, _ = changelog.split_changelog((self.root / "CHANGELOG.md").read_text())
        self.assertEqual(body, "\n" + changelog.UNRELEASED_STUB + "\n")

    def test_the_real_changelog_parses_and_keeps_every_bullet(self):
        text = (REPO / "CHANGELOG.md").read_text(encoding="utf-8")
        normalized = changelog.normalize_text(text)
        bullets = lambda s: sorted(l for l in s.splitlines() if l.startswith("- "))
        self.assertEqual(bullets(text), bullets(normalized))
        headings = [l for l in changelog.split_changelog(normalized)[1].splitlines()
                    if l.startswith("### ")]
        self.assertEqual(len(headings), len(set(headings)), "one heading per section")


class ReleaseTest(Fixture):
    def test_rolls_unreleased_and_fragments_into_a_dated_section(self):
        self.changelog("\n### Added\n\n- from unreleased\n\n")
        write(self.root, "changelog.d/10-a.md", "### Fixed\n\n- fix ten (#10).\n")
        write(self.root, "changelog.d/11-b.md", "### Added\n\n- add eleven (#11).\n\n### Upgrade notes\n\n- note (#11).\n")
        result = self.run_script("release", "--version", "0.17.0", "--date", "2026-09-20", "--require-upgrade-notes")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.root / "CHANGELOG.md").read_text()
        self.assertEqual(
            text,
            PREAMBLE
            + "\n" + changelog.UNRELEASED_STUB + "\n"
            + "## [0.17.0] - 2026-09-20\n\n"
            + "### Upgrade notes\n\n- note (#11).\n\n"
            + "### Added\n\n- from unreleased\n\n- add eleven (#11).\n\n"
            + "### Fixed\n\n- fix ten (#10).\n\n"
            + RELEASED,
        )
        self.assertEqual(changelog.fragment_paths(self.root), [], "fragments consumed")
        self.assertTrue((self.root / "changelog.d/README.md").exists())
        # The next release starts from the stub plus new fragments.
        write(self.root, "changelog.d/12-c.md", "### Fixed\n\n- fix twelve (#12).\n")
        result = self.run_script("release", "--version", "0.17.1", "--date", "2026-09-21")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.root / "CHANGELOG.md").read_text()
        self.assertIn("## [0.17.1] - 2026-09-21\n\n### Fixed\n\n- fix twelve (#12).\n\n## [0.17.0]", text)
        self.assertEqual(text.count(changelog.UNRELEASED_STUB), 1)

    def test_preview_prints_the_section_and_writes_nothing(self):
        before = self.changelog().read_text()
        write(self.root, "changelog.d/10-a.md", "### Fixed\n\n- fix ten (#10).\n")
        result = self.run_script("preview", "--version", "0.17.0", "--date", "2026-09-20")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "## [0.17.0] - 2026-09-20\n\n### Fixed\n\n- fix ten (#10).\n")
        self.assertEqual((self.root / "CHANGELOG.md").read_text(), before)
        self.assertEqual(len(changelog.fragment_paths(self.root)), 1)

    def test_a_minor_needs_an_upgrade_note(self):
        self.changelog()
        write(self.root, "changelog.d/10-a.md", "### Fixed\n\n- fix ten (#10).\n")
        result = self.run_script("release", "--version", "0.17.0", "--require-upgrade-notes")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Upgrade notes", result.stderr)
        self.assertEqual(len(changelog.fragment_paths(self.root)), 1, "nothing consumed")
        write(self.root, "changelog.d/10-b.md", "### Upgrade notes\n\n- None.\n")
        result = self.run_script("release", "--version", "0.17.0", "--require-upgrade-notes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("### Upgrade notes\n\n- None.\n", (self.root / "CHANGELOG.md").read_text())

    def test_refuses_an_empty_release_and_a_repeated_version(self):
        self.changelog()
        result = self.run_script("release", "--version", "0.17.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("nothing to release", result.stderr)
        write(self.root, "changelog.d/10-a.md", "### Fixed\n\n- fix ten (#10).\n")
        result = self.run_script("release", "--version", "0.16.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("already has", result.stderr)
        result = self.run_script("release", "--version", "v0.17.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("SemVer", result.stderr)


class GuardTest(Fixture):
    def setUp(self):
        super().setUp()
        self.git("init", "--quiet", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.changelog()
        self.git("add", "-A")
        self.git("commit", "--quiet", "-m", "base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "-b", "feature")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True,
                              capture_output=True, text=True)

    def commit(self, name: str, text: str):
        write(self.root, name, text)
        self.git("add", "-A")
        self.git("commit", "--quiet", "-m", name)

    def test_a_fragment_passes_and_a_changelog_edit_fails(self):
        self.commit("changelog.d/10-a.md", "### Fixed\n\n- x (#10).\n")
        self.assertEqual(self.run_script("guard", "--base", self.base, "--branch", "feature").returncode, 0)
        self.commit("CHANGELOG.md", PREAMBLE + "\n### Fixed\n\n- x\n\n" + RELEASED)
        result = self.run_script("guard", "--base", self.base, "--branch", "feature")
        self.assertEqual(result.returncode, 1)
        self.assertIn("changelog.d/", result.stderr)
        self.assertIn("release:manual-changelog", result.stderr)

    def test_the_release_branch_and_the_label_are_the_two_doors(self):
        self.commit("CHANGELOG.md", PREAMBLE + "\n### Fixed\n\n- x\n\n" + RELEASED)
        self.assertEqual(
            self.run_script("guard", "--base", self.base, "--branch", "release/v0.17.0").returncode, 0)
        for label in ("release:manual-changelog", "changelog:manual"):
            with self.subTest(label=label):
                self.assertEqual(
                    self.run_script("guard", "--base", self.base, "--branch", "feature",
                                    "--label", "type:bug", "--label", label).returncode, 0)
        self.assertEqual(
            self.run_script("guard", "--base", self.base, "--branch", "feature",
                            "--label", "type:bug").returncode, 1)

    def test_a_changelog_edit_on_main_since_branching_is_not_the_prs(self):
        # The three-dot diff: main moving on (a release roll) must not fail
        # an unrelated open PR.
        self.commit("other.txt", "x\n")
        self.git("checkout", "--quiet", "main")
        self.commit("CHANGELOG.md", PREAMBLE + "\n### Fixed\n\n- rolled\n\n" + RELEASED)
        self.git("checkout", "--quiet", "feature")
        self.assertEqual(self.run_script("guard", "--base", "main", "--branch", "feature").returncode, 0)


if __name__ == "__main__":
    unittest.main()
