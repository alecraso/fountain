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

    def test_sandbox_family_fields_propagate_without_registration(self):
        owners = ["Sandbox", "SandboxDetail", "SandboxConversation", "Runner", "ConversationTreeNode", "UsageTotal"]
        for owner in owners:
            self.contract["schemas"][owner]["properties"]["future_switch"] = {
                "type": "boolean", "required": False, "nullable": True,
            }
        output = swiftgen.Generator(self.contract).render()
        self.assertEqual(output.count('case futureSwitch = "future_switch"'), len(owners))
        self.assertIn("extension Sandbox {", output)
        self.assertIn("public struct RunnerRef:", output)
        self.assertIn("extension SandboxDetail {", output)

    def test_reused_inline_shapes_cannot_drift_silently(self):
        self.contract["schemas"]["SandboxDetail"]["properties"]["runner"]["properties"]["other"] = {"type": "string"}
        with self.assertRaisesRegex(ValueError, "Incompatible reused inline shape"):
            swiftgen.Generator(self.contract).render()

    def test_usage_alias_rejects_incompatible_fields(self):
        self.contract["schemas"]["UsageTotal"]["properties"]["input"]["type"] = "string"
        with self.assertRaisesRegex(ValueError, "Incompatible usage field: input"):
            swiftgen.Generator(self.contract).render()

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
