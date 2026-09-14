import { test } from "node:test";
import assert from "node:assert/strict";
import { TurnFollower } from "../src/turn.ts";
import type { Block } from "../src/types.ts";

test("plan snapshots survive the turn feed without becoming assistant text", () => {
  const follower = new TurnFollower(1, "t1");
  const block: Block = {
    kind: "plan",
    body: [{ content: "Verify the change", status: "in_progress", priority: "high" }],
  };
  const events = follower.apply({ id: 1, ts: "2026-09-14T00:00:00Z", kind: "output", stream: "acp", turn_id: "t1", blocks: [block] });
  assert.deepEqual(events.map(event => event.type), ["block"]);
  assert.deepEqual(events[0], {
    type: "block", block,
    event: { id: 1, ts: "2026-09-14T00:00:00Z", kind: "output", stream: "acp", turn_id: "t1", blocks: [block] },
  });
  assert.equal(follower.text, "");
});
