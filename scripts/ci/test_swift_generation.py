"""An additive wire field changes generated Swift without a property registry."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("swiftgen", ROOT / "scripts/sdk-contract/generate-swift.py")
swiftgen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(swiftgen)


class SwiftGeneration(unittest.TestCase):
    def setUp(self):
        self.contract = json.loads((ROOT / "sdk/contract/contract.json").read_text())

    def test_additive_fields_propagate_without_registration(self):
        changed = copy.deepcopy(self.contract)
        for owner in ["ConversationCreateRequest", "Conversation", "Turn"]:
            changed["schemas"][owner]["properties"]["future_switch"] = {
                "type": "boolean", "required": False, "nullable": True,
            }
        output = swiftgen.Generator(changed).render()
        self.assertEqual(output.count('case futureSwitch = "future_switch"'), 3)
        self.assertIn("public var futureSwitch: Bool?", output)
        self.assertIn("case .futureSwitch: _futureSwitch = .null", output)
        self.assertIn("try _futureSwitch.encode(into: &container, forKey: .futureSwitch)", output)
        self.assertNotIn("futureSwitch", swiftgen.Generator(self.contract).render())

    def test_generation_is_deterministic(self):
        self.assertEqual(swiftgen.Generator(self.contract).render(), swiftgen.Generator(self.contract).render())

    def test_unknown_shapes_fail_loudly(self):
        self.contract["schemas"]["Conversation"]["properties"]["future_union"] = {
            "oneOf": [{"type": "string"}, {"type": "integer"}], "required": False,
        }
        with self.assertRaisesRegex(ValueError, "Unsupported union at Conversation.future_union"):
            swiftgen.Generator(self.contract).render()


if __name__ == "__main__":
    unittest.main()
