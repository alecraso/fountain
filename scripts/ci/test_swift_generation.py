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

    def test_resource_roots_and_nested_fields_propagate(self):
        # Each root is probed independently so a forgotten root cannot be
        # hidden by another model generating the same property.
        for owner in swiftgen.RESOURCE_ROOTS + ["VaultSecret"]:
            with self.subTest(owner=owner):
                contract = copy.deepcopy(self.contract)
                node = contract["schemas"]
                for key in swiftgen.SCHEMA_PATHS.get(owner, [owner]):
                    node = node[key]
                node["properties"]["future_switch"] = {
                    "type": "boolean", "required": False, "nullable": True,
                }
                output = swiftgen.Generator(contract).render()
                self.assertEqual(output.count('case futureSwitch = "future_switch"'), 1)
                self.assertIn("public var futureSwitch: Bool?", output)
                if owner in swiftgen.INPUT_ORDERS:
                    self.assertIn("case .futureSwitch: _futureSwitch = .null", output)
        for path in [
            ["Teammate", "properties", "presence"],
            ["CatalogResponse", "properties", "data", "properties", "apps"],
            ["ApplySecretResult"],
        ]:
            with self.subTest(path=path):
                contract = copy.deepcopy(self.contract)
                node = contract["schemas"]
                for key in path:
                    node = node[key]
                node["properties"]["future_label"] = {"type": "string", "required": True}
                output = swiftgen.Generator(contract).render()
                self.assertEqual(output.count('case futureLabel = "future_label"'), 1)
                self.assertIn("public var futureLabel: String\n", output)

    def test_shared_skill_shape_additions_and_conflicts(self):
        for owner in ["Agent", "AgentUpdate"]:
            self.contract["schemas"][owner]["properties"]["skills"]["items"]["properties"]["future_label"] = {
                "type": "string", "required": False,
            }
        output = swiftgen.Generator(self.contract).render()
        self.assertEqual(output.count('case futureLabel = "future_label"'), 1)
        self.contract["schemas"]["AgentUpdate"]["properties"]["skills"]["items"]["properties"]["future_label"]["type"] = "boolean"
        with self.assertRaisesRegex(ValueError, "Incompatible reused inline shape: AgentSkillsItem"):
            swiftgen.Generator(self.contract).render()

    def test_secret_alias_rejects_incompatible_shared_fields(self):
        self.contract["schemas"]["VaultSecret"]["properties"]["key"]["type"] = "integer"
        with self.assertRaisesRegex(ValueError, "Incompatible secret field: key"):
            swiftgen.Generator(self.contract).render()

    def test_optional_compat_pins_reach_a_live_property(self):
        # The table carries the whole backward-compatibility story. A pin whose
        # owner or key the contract renamed stops applying in silence, flipping
        # a public property back to non-Optional with every other gate green.
        generator = swiftgen.Generator(self.contract)
        generator.render()
        for owner, key in sorted(swiftgen.OPTIONAL_COMPAT):
            with self.subTest(owner=owner, key=key):
                self.assertIn(owner, generator.models)
                fields = {field[0]: field[3] for field in generator.models[owner]}
                self.assertIn(key, fields)

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
