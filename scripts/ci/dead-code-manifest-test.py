"""Run the real locked analyzer against a caller deleted between reports.

Run after `mix deps.get`; all compilation stays in a disposable fixture.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DeadCodeManifestTest(unittest.TestCase):
    def test_deleted_caller_no_longer_hides_unused_callee(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "apps/fountain"
            (app / "lib").mkdir(parents=True)
            (root / "scripts").mkdir()
            shutil.copy2(ROOT / "scripts/dead-code.sh", root / "scripts/dead-code.sh")
            for dependency in ("mix_unused", "libgraph"):
                shutil.copytree(ROOT / "deps" / dependency, root / "deps" / dependency)
            (app / "mix.exs").write_text('''defmodule Fixture.MixProject do
  use Mix.Project
  def project do
    [app: :fountain, version: "0.1.0", build_path: "../../_build",
     compilers: [:unused] ++ Mix.compilers(),
     unused: [ignore: [Caller, {:_, ~r/^__/, :_}]],
     deps: [{:mix_unused, path: "../../deps/mix_unused"},
            {:libgraph, path: "../../deps/libgraph", override: true}]]
  end
end
''')
            (app / "lib/target.ex").write_text("defmodule Target do\n  def work, do: :ok\nend\n")
            caller = app / "lib/caller.ex"
            caller.write_text("defmodule Caller do\n  def work, do: Target.work()\nend\n")
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("MIX_")}

            def report():
                result = subprocess.run(
                    ["bash", str(root / "scripts/dead-code.sh"), "elixir"],
                    cwd=root, env=env, text=True, capture_output=True, timeout=120,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result.stdout

            self.assertNotIn("Target.work/0 is unused", report())
            manifest = root / "_build/dev/lib/fountain/.mix/unused.manifest"
            self.assertTrue(manifest.is_file())
            dependency_beams = list((root / "_build/dev/lib/mix_unused/ebin").glob("*.beam"))
            self.assertTrue(dependency_beams)
            cached = {path: path.stat().st_mtime_ns for path in dependency_beams}
            other_environment = root / "_build/test/lib/fountain/keep"
            other_environment.parent.mkdir(parents=True)
            other_environment.write_text("test build")

            caller.unlink()
            self.assertIn("hint: Target.work/0 is unused", report())
            self.assertEqual(cached, {path: path.stat().st_mtime_ns for path in cached})
            self.assertEqual(other_environment.read_text(), "test build")


if __name__ == "__main__":
    unittest.main()
