import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { isAgentEvent } from "../dist/index.js";

const fixture = async (name) =>
  JSON.parse(
    await readFile(new URL(`../../protocol/fixtures/${name}.json`, import.meta.url), "utf8"),
  );

test("all unified AgentEvent discriminators pass runtime validation", async () => {
  const events = await fixture("agent-events");
  assert.equal(events.length, 13);
  assert.equal(events.every(isAgentEvent), true);
  const nullUnknownEvents = await fixture("agent-events-null-unknown");
  assert.equal(nullUnknownEvents.every(isAgentEvent), true);
});

test("invalid AgentEvent invariants are rejected", async () => {
  assert.equal(isAgentEvent(await fixture("agent-event-invalid-sequence")), false);
  assert.equal(isAgentEvent(await fixture("agent-event-invalid-approval")), false);
  assert.equal(isAgentEvent(await fixture("agent-event-invalid-enum-types")), false);
  assert.equal(isAgentEvent(await fixture("agent-event-invalid-option-extra")), false);
  const nullEvents = await fixture("agent-events-invalid-null");
  assert.equal(nullEvents.every((event) => !isAgentEvent(event)), true);
});
