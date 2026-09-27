import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import Ajv2020 from "ajv/dist/2020.js";

import {
  isEncryptedPayload,
  isEnvelope,
  isMessageType,
  PROTOCOL_VERSION,
} from "../dist/index.js";

const request = {
  version: PROTOCOL_VERSION,
  id: "request-1",
  type: "project.list",
  sourceDeviceId: "iphone-1",
  targetDeviceId: "mac-1",
  timestamp: "2026-09-22T00:00:00.000Z",
  payload: {},
};

const fixtureUrl = (name) => new URL(`../fixtures/${name}.json`, import.meta.url);
const schemaUrl = (name) => new URL(`../schema/${name}.schema.json`, import.meta.url);
const readJson = async (url) => JSON.parse(await readFile(url, "utf8"));

test("an envelope survives JSON serialization", () => {
  assert.equal(isEnvelope(JSON.parse(JSON.stringify(request))), true);
});

test("message namespaces are closed", () => {
  assert.equal(isMessageType("agent.event"), true);
  assert.equal(isMessageType("native.event"), false);
});

test("encrypted payloads expose only versioned ciphertext", () => {
  assert.equal(isEncryptedPayload({ encryptionVersion: 1, ciphertext: "base64" }), true);
  assert.equal(isEncryptedPayload({ encryptionVersion: 2, ciphertext: "base64" }), false);
});

test("invalid optional routing metadata is rejected", () => {
  assert.equal(isEnvelope({ ...request, targetDeviceId: 42 }), false);
});

test("runtime and Draft 2020-12 schema agree on envelope fixtures", async () => {
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  ajv.addFormat("date-time", {
    type: "string",
    validate: isProtocolTimestamp,
  });

  const validateRequest = ajv.compile(await readJson(schemaUrl("envelope")));
  const validateResponse = ajv.compile(await readJson(schemaUrl("response-envelope")));
  const validateAgentEvent = ajv.compile(await readJson(schemaUrl("agent-event")));
  const sharedSchema = await readJson(schemaUrl("shared-types"));
  const gitChangesSchema = await readJson(schemaUrl("git-changes"));
  const projectSearchSchema = await readJson(schemaUrl("project-search"));
  ajv.addSchema(sharedSchema);
  const validateSessionSnapshot = ajv.compile(await readJson(schemaUrl("session-snapshot")));
  const validateProject = ajv.getSchema(`${sharedSchema.$id}#/$defs/project`);
  const validateSession = ajv.getSchema(`${sharedSchema.$id}#/$defs/session`);
  const validateFileEntry = ajv.getSchema(`${sharedSchema.$id}#/$defs/fileEntry`);
  ajv.addSchema(gitChangesSchema);
  ajv.addSchema(projectSearchSchema);
  const validateGitChange = ajv.compile({ $ref: `${gitChangesSchema.$id}#/$defs/gitChange` });
  const validateProjectChangesRequest = ajv.compile({ $ref: `${gitChangesSchema.$id}#/$defs/projectChangesRequest` });
  const validateProjectChangesResponse = ajv.compile({ $ref: `${gitChangesSchema.$id}#/$defs/projectChangesResponse` });
  const validateProjectDiffRequest = ajv.compile({ $ref: `${gitChangesSchema.$id}#/$defs/projectDiffRequest` });
  const validateProjectDiffResponse = ajv.compile({ $ref: `${gitChangesSchema.$id}#/$defs/projectDiffResponse` });
  const validateProjectSearchRequest = ajv.compile({ $ref: `${projectSearchSchema.$id}#/$defs/projectSearchFilesRequest` });
  const validateProjectCancelSearchRequest = ajv.compile({ $ref: `${projectSearchSchema.$id}#/$defs/projectCancelSearchRequest` });
  const validateProjectSearchResponse = ajv.compile({ $ref: `${projectSearchSchema.$id}#/$defs/projectSearchFilesResponse` });
  const validRequest = await readJson(fixtureUrl("valid-request"));
  const validResponse = await readJson(fixtureUrl("valid-response-no-payload"));
  const validNullResponse = await readJson(fixtureUrl("valid-response-null-payload"));
  const validNullDetailsResponse = await readJson(fixtureUrl("valid-response-null-error-details"));
  const invalidRequestNames = [
    "invalid-empty-id",
    "invalid-encrypted-payload",
    "invalid-extra-field",
    "invalid-offset-timestamp",
    "invalid-timestamp",
    "invalid-type",
    "invalid-version",
  ];
  const invalidResponseNames = [
    "invalid-response-empty-error",
    "invalid-response-error-extra",
    "invalid-response-null-error",
    "invalid-response-null-target",
  ];

  assert.equal(validateRequest(validRequest), true, JSON.stringify(validateRequest.errors));
  assert.equal(isEnvelope(validRequest), true);
  assert.equal(validateResponse(validResponse), true, JSON.stringify(validateResponse.errors));
  assert.equal(isEnvelope(validResponse), true);
  assert.equal(validateResponse(validNullResponse), true, JSON.stringify(validateResponse.errors));
  assert.equal(isEnvelope(validNullResponse), true);
  assert.equal(validateResponse(validNullDetailsResponse), true, JSON.stringify(validateResponse.errors));
  assert.equal(isEnvelope(validNullDetailsResponse), true);

  for (const name of invalidRequestNames) {
    const fixture = await readJson(fixtureUrl(name));
    assert.equal(validateRequest(fixture), false, name);
    assert.equal(isEnvelope(fixture), false, name);
  }

  for (const name of invalidResponseNames) {
    const fixture = await readJson(fixtureUrl(name));
    assert.equal(validateResponse(fixture), false, name);
    assert.equal(isEnvelope(fixture), false, name);
  }

  const agentEvents = await readJson(fixtureUrl("agent-events"));
  assert.equal(agentEvents.length, 13);
  for (const event of agentEvents) {
    assert.equal(validateAgentEvent(event), true, JSON.stringify(validateAgentEvent.errors));
  }
  for (const name of [
    "agent-event-invalid-sequence",
    "agent-event-invalid-approval",
    "agent-event-invalid-enum-types",
    "agent-event-invalid-option-extra",
  ]) {
    assert.equal(validateAgentEvent(await readJson(fixtureUrl(name))), false, name);
  }
  for (const event of await readJson(fixtureUrl("agent-events-invalid-null"))) {
    assert.equal(validateAgentEvent(event), false, JSON.stringify(event));
  }
  for (const event of await readJson(fixtureUrl("agent-events-null-unknown"))) {
    assert.equal(validateAgentEvent(event), true, JSON.stringify(validateAgentEvent.errors));
  }

  const sharedTypes = await readJson(fixtureUrl("shared-types"));
  assert.equal(validateProject(sharedTypes.project), true, JSON.stringify(validateProject.errors));
  assert.equal(validateSession(sharedTypes.session), true, JSON.stringify(validateSession.errors));
  assert.equal(validateFileEntry(sharedTypes.fileEntry), true, JSON.stringify(validateFileEntry.errors));

  const gitChanges = await readJson(fixtureUrl("git-changes"));
  assert.equal(validateProjectChangesRequest(gitChanges.projectChangesRequest), true);
  assert.equal(validateProjectChangesResponse(gitChanges.projectChangesResponse), true);
  assert.equal(validateProjectChangesResponse(gitChanges.nonGitProjectChangesResponse), true);
  assert.equal(validateProjectDiffRequest(gitChanges.projectDiffRequest), true);
  assert.equal(validateProjectDiffResponse(gitChanges.projectDiffResponse), true);
  assert.equal(validateProjectDiffResponse(gitChanges.binaryProjectDiffResponse), true);
  for (const change of gitChanges.projectChangesResponse.changes) {
    assert.equal(validateGitChange(change), true, JSON.stringify(validateGitChange.errors));
  }
  assert.equal(validateGitChange(await readJson(fixtureUrl("git-changes-invalid-renamed-missing-previous-path"))), false);
  assert.equal(validateGitChange(await readJson(fixtureUrl("git-changes-invalid-previous-path-on-modified"))), false);
  assert.equal(validateGitChange(await readJson(fixtureUrl("git-changes-invalid-extra-field"))), false);
  assert.equal(validateProjectDiffResponse(await readJson(fixtureUrl("git-changes-invalid-binary-diff"))), false);

  const projectSearch = await readJson(fixtureUrl("project-search"));
  assert.equal(validateProjectSearchRequest(projectSearch.projectSearchFilesRequest), true);
  assert.equal(validateProjectCancelSearchRequest(projectSearch.projectCancelSearchRequest), true);
  assert.equal(validateProjectSearchResponse(projectSearch.projectSearchFilesResponse), true);
  assert.equal(validateProjectSearchRequest(await readJson(fixtureUrl("project-search-invalid-limit"))), false);
  assert.equal(validateProjectSearchRequest(await readJson(fixtureUrl("project-search-invalid-query"))), false);
  assert.equal(validateProjectSearchRequest(await readJson(fixtureUrl("project-search-invalid-unicode-whitespace"))), false);
  assert.equal(validateProjectSearchRequest(await readJson(fixtureUrl("project-search-valid-feff"))), true);
  assert.equal(validateProjectSearchRequest(await readJson(fixtureUrl("project-search-valid-zero-width-space"))), true);
  assert.equal(validateProjectSearchRequest(await readJson(fixtureUrl("project-search-invalid-extra-field"))), false);
  assert.equal(validateProjectSearchResponse(await readJson(fixtureUrl("project-search-invalid-result-extra-field"))), false);
  assert.equal(validateProjectSearchResponse(await readJson(fixtureUrl("project-search-invalid-result-size"))), false);
  assert.equal(validateProjectSearchResponse(await readJson(fixtureUrl("project-search-invalid-result-null"))), false);
  assert.equal(validateProjectSearchResponse({
    ...projectSearch.projectSearchFilesResponse,
    results: Array.from({ length: 101 }, () => projectSearch.projectSearchFilesResponse.results[0]),
  }), false);

  assert.equal(
    validateSessionSnapshot(await readJson(fixtureUrl("session-snapshot"))),
    true,
    JSON.stringify(validateSessionSnapshot.errors),
  );
  for (const name of ["session-snapshot-invalid-pending", "session-snapshot-invalid-sequence"]) {
    assert.equal(validateSessionSnapshot(await readJson(fixtureUrl(name))), false, name);
  }
});

function isProtocolTimestamp(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/.exec(value);
  if (match === null) return false;
  const values = match.slice(1).map(Number);
  const [year, month, day, hour, minute, second] = values;
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return (
    month >= 1 && month <= 12 && day >= 1 && day <= days[month - 1] &&
    hour <= 23 && minute <= 59 && second <= 59
  );
}
