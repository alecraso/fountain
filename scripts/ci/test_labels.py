"""Label migration preserves assignments and refuses ambiguous renames."""

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "sync_labels", Path(__file__).resolve().parents[1] / "sync-labels.py")
LABELS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LABELS)


class LabelsTest(unittest.TestCase):
    def test_renames_existing_label_instead_of_creating_a_replacement(self):
        definition = {"name": "type:bug", "previous_name": "bug",
                      "color": "007F8B", "description": "Broken behavior."}
        existing = [{"id": 17, "name": "bug", "color": "d73a4a", "description": "Old"}]
        self.assertEqual(LABELS.plan_changes([definition], existing), [
            ("bug", {"name": "type:bug", "color": "007F8B", "description": "Broken behavior."})])

    def test_rerun_is_empty_and_does_not_touch_unmanaged_labels(self):
        definition = {"name": "type:bug", "previous_name": "bug",
                      "color": "007F8B", "description": "Broken behavior."}
        existing = [{"id": 17, "name": "type:bug", "color": "007f8b",
                     "description": "Broken behavior."},
                    {"id": 18, "name": "unmanaged", "color": "ffffff", "description": "Keep"}]
        self.assertEqual(LABELS.plan_changes([definition], existing), [])

    def test_old_and_new_labels_both_present_refuses_the_plan(self):
        definition = {"name": "type:bug", "previous_name": "bug",
                      "color": "007F8B", "description": "Broken behavior."}
        with self.assertRaisesRegex(ValueError, "Both"):
            LABELS.plan_changes([definition], [{"id": 1, "name": "bug"},
                                              {"id": 2, "name": "type:bug"}])

    def test_new_definition_creates_a_label_and_duplicate_names_are_rejected(self):
        definition = {"name": "area:api", "color": "1D76DB", "description": "API"}
        self.assertEqual(LABELS.plan_changes([definition], []), [(None, definition)])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            LABELS.plan_changes([definition, {**definition, "name": "AREA:API"}], [])


if __name__ == "__main__":
    unittest.main()
