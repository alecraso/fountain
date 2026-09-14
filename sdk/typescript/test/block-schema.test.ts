import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import AjvModule from "@redocly/ajv";

// CI checks that this committed projection matches the exported OpenAPI schema.
// Restore its per-property required flags to JSON Schema's sibling list; keep
// nullable and composition exactly where the server declared them.
function schemaFromContract(node: Record<string, any>): Record<string, any> {
  const { required: _required, properties, items, oneOf, ...schema } = node;
  if (properties) {
    const entries = Object.entries(properties) as [string, Record<string, any>][];
    schema.properties = Object.fromEntries(entries.map(([key, value]) => [key, schemaFromContract(value)]));
    schema.required = entries.filter(([, value]) => value.required).map(([key]) => key);
  }
  if (items) schema.items = schemaFromContract(items);
  if (oneOf) schema.oneOf = oneOf.map(schemaFromContract);
  return schema;
}

const contract = JSON.parse(readFileSync(new URL("../../contract/contract.json", import.meta.url), "utf8"));

test("Block.body compiles strictly and validates nullable text or a plan snapshot", () => {
  const schema = schemaFromContract(contract.schemas.Block.properties.body);
  const validate = new AjvModule.default({ strict: true, coerceTypes: false }).compile(schema);
  const entry = { content: "Verify the change", status: "in_progress", priority: "high" };

  for (const body of [null, "", "reply", [], [entry]]) {
    assert.equal(validate(body), true, `${JSON.stringify(body)}: ${JSON.stringify(validate.errors)}`);
  }
  for (const body of [42, false, {}, [null], [{ content: "Missing status" }], [{ ...entry, status: "unknown" }]]) {
    assert.equal(validate(body), false, `accepted invalid body: ${JSON.stringify(body)}`);
  }
});
