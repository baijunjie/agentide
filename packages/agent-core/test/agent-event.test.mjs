import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { isAgentEvent, isReportEvent } from "../dist/index.js";

const fixture = async (name) =>
  JSON.parse(
    await readFile(new URL(`../../protocol/fixtures/${name}.json`, import.meta.url), "utf8"),
  );

test("all unified AgentEvent discriminators pass runtime validation", async () => {
  const events = await fixture("agent-events");
  assert.equal(events.length, 19);
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
  const invalidReports = await fixture("agent-report-events-invalid");
  assert.equal(invalidReports.every((event) => !isAgentEvent(event)), true);
  const runtimeInvalidReports = await fixture("agent-report-events-runtime-invalid");
  assert.equal(runtimeInvalidReports.every((event) => !isAgentEvent(event)), true);

  const reportWithExtraField = {
    id: "extra-report",
    sessionId: "s1",
    sequence: 1,
    timestamp: "2026-09-22T00:00:00.000Z",
    type: "report",
    reportVersion: 1,
    reportId: "r-extra",
    kind: "plan",
    title: "Plan",
    summary: "Unexpected field",
    payload: { steps: [] },
    extra: true,
  };
  assert.equal(isReportEvent(reportWithExtraField), false);
  assert.equal(isAgentEvent(reportWithExtraField), false);
});
