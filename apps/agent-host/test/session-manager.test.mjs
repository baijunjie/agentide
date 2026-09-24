import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createAgentHostServer, ProjectStore, SessionManager, SessionStore } from "../dist/index.js";

class EventQueue {
  buffered = [];
  waiting = [];
  push(value) {
    const resolve = this.waiting.shift();
    if (resolve) resolve({ done: false, value });
    else this.buffered.push(value);
  }
  [Symbol.asyncIterator]() {
    return { next: async () => this.buffered.length > 0 ? { done: false, value: this.buffered.shift() } : new Promise((resolve) => this.waiting.push(resolve)) };
  }
}

class FakeAdapter {
  type = "codex";
  queues = new Map();
  sent = [];
  resumed = [];
  interactions = [];
  capabilities() { return { approvals: true, questions: false, resumeSession: true }; }
  async createSession(options) {
    const queue = new EventQueue();
    this.queues.set(options.sessionId, queue);
    queue.push(event(options.sessionId, "session.started", { nativeSessionId: "native-1" }));
    return {
      id: options.sessionId,
      projectId: options.projectId,
      agentType: "codex",
      nativeSessionId: "native-1",
      title: options.initialPrompt,
      status: "starting",
      createdAt: "2026-09-24T00:00:00.000Z",
      updatedAt: "2026-09-24T00:00:00.000Z",
    };
  }
  async resumeSession(nativeSessionId) {
    this.resumed.push(nativeSessionId);
    const queue = new EventQueue();
    this.queues.set(nativeSessionId, queue);
    return {
      id: nativeSessionId,
      projectId: "",
      agentType: "codex",
      nativeSessionId,
      title: "resumed",
      status: "running",
      createdAt: "2026-09-24T00:00:00.000Z",
      updatedAt: "2026-09-24T00:00:00.000Z",
    };
  }
  async sendMessage(sessionId, input) {
    this.sent.push({ sessionId, input });
    this.queues.get(sessionId).push(event(sessionId, "status", { status: "running" }));
  }
  async cancel() {}
  async respondToInteraction(sessionId, interactionId, response) { this.interactions.push({ sessionId, interactionId, response }); }
  events(sessionId) { return this.queues.get(sessionId); }
}

test("session manager persists normalized events and resumes native sessions", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-sessions-"));
  context.after(() => rm(base, { recursive: true, force: true }));
  const root = join(base, "project");
  const bin = join(base, "bin");
  await mkdir(root); await mkdir(bin);
  await writeFile(join(bin, "codex"), "#!/bin/sh\n");
  await chmod(join(bin, "codex"), 0o755);
  const projects = new ProjectStore(join(base, "projects.json"), bin);
  const project = await projects.add(root);
  const sessionPath = join(base, "sessions.json");
  const adapter = new FakeAdapter();
  const manager = new SessionManager(projects, new SessionStore(sessionPath), new Map([["codex", adapter]]));
  const session = await manager.create({ projectId: project.id, agentType: "codex", initialPrompt: "Fix tests" });
  assert.deepEqual(adapter.sent, [{ sessionId: session.id, input: { content: "Fix tests" } }]);

  await waitFor(async () => (await manager.events(session.id)).length >= 2);
  const createdEvents = await manager.events(session.id);
  assert.equal(createdEvents[0].sequence, 0);
  assert.equal(JSON.parse(await readFile(sessionPath, "utf8")).events, undefined);
  assert.match(await readFile(join(`${sessionPath}.events`, `${encodeURIComponent(session.id)}.jsonl`), "utf8"), /session\.started/);
  adapter.queues.get(session.id).push(event(session.id, "approval.requested", { interactionId: "expired", title: "Approve", actions: ["reject"] }));
  adapter.queues.get(session.id).push(event(session.id, "status", { status: "waiting_user" }));
  await waitFor(async () => (await manager.get(session.id)).status === "waiting_user");

  const resumedAdapter = new FakeAdapter();
  const restarted = new SessionManager(projects, new SessionStore(sessionPath), new Map([["codex", resumedAdapter]]));
  await assert.rejects(
    restarted.respond(session.id, "expired", { kind: "approval", action: "reject" }),
    /Interaction expired/,
  );
  await Promise.all([
    restarted.sendMessage(session.id, { content: "Continue" }),
    restarted.sendMessage(session.id, { content: "Then summarize" }),
  ]);
  assert.deepEqual(resumedAdapter.resumed, ["native-1"]);
  assert.deepEqual(resumedAdapter.sent, [
    { sessionId: "native-1", input: { content: "Continue" } },
    { sessionId: "native-1", input: { content: "Then summarize" } },
  ]);
  await restarted.respond(session.id, "new-approval", { kind: "approval", action: "approve_once" });
  assert.deepEqual(resumedAdapter.interactions, [{ sessionId: "native-1", interactionId: "new-approval", response: { kind: "approval", action: "approve_once" } }]);
  assert.equal((await restarted.events(session.id))[0].type, "session.started");
  assert.equal((await restarted.get(session.id)).status, "running");
  assert.ok((await restarted.events(session.id)).some((value) => value.code === "agent_interaction_expired"));
});

test("local IPC exposes the unified session operation boundary", async (context) => {
  const calls = [];
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Task", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  const sessions = {
    async list(projectId) { calls.push(["list", projectId]); return [session]; },
    async get(sessionId) { calls.push(["get", sessionId]); return session; },
    async events(sessionId, afterSequence) { calls.push(["events", sessionId, afterSequence]); return [event(sessionId, "status", { status: "running" })]; },
    async create(input) { calls.push(["create", input]); return session; },
    async sendMessage(sessionId, input) { calls.push(["message", sessionId, input]); },
    async cancel(sessionId) { calls.push(["cancel", sessionId]); },
    async respond(sessionId, interactionId, response) { calls.push(["respond", sessionId, interactionId, response]); },
  };
  const server = createAgentHostServer(new ProjectStore("/unused", ""), sessions);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  const base = `http://127.0.0.1:${address.port}`;

  assert.equal((await json(`${base}/sessions`, "POST", { projectId: "project-1", agentType: "codex", initialPrompt: "Task" }, 201)).id, session.id);
  assert.equal((await json(`${base}/sessions?projectId=project-1`, "GET")).sessions.length, 1);
  assert.equal((await json(`${base}/sessions/session-1`, "GET")).id, session.id);
  assert.equal((await json(`${base}/sessions/session-1/events?afterSequence=2`, "GET")).events.length, 1);
  await json(`${base}/sessions/session-1/messages`, "POST", { content: "Continue" }, 204);
  await json(`${base}/sessions/session-1/cancel`, "POST", {}, 204);
  await json(`${base}/sessions/session-1/interactions`, "POST", { kind: "approval", interactionId: "42", action: "approve_once" }, 204);
  assert.deepEqual(calls.at(-1), ["respond", "session-1", "42", { kind: "approval", action: "approve_once" }]);
});

test("session store does not expose a mutation when atomic persistence fails", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-store-failure-"));
  context.after(() => rm(base, { recursive: true, force: true }));
  const dataDirectory = join(base, "data");
  const path = join(dataDirectory, "sessions.json");
  const store = new SessionStore(path);
  assert.deepEqual(await store.list(), []);
  await mkdir(dataDirectory);
  await rename(dataDirectory, join(base, "parked"));
  await writeFile(dataDirectory, "not a directory");
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Task", status: "starting", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  await assert.rejects(store.create(session));
  assert.deepEqual(await store.list(), []);
});

test("session store derives state from atomic events and ignores a truncated JSONL tail", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-store-recovery-"));
  context.after(() => rm(base, { recursive: true, force: true }));
  const path = join(base, "sessions.json");
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Task", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  const store = new SessionStore(path);
  await store.create(session);
  await store.record(session.id, event(session.id, "approval.requested", { interactionId: "42", title: "Approve", actions: ["reject"] }));
  assert.equal((await new SessionStore(path).get(session.id)).status, "waiting_user");
  await store.record(session.id, event(session.id, "turn.completed", { outcome: "failed" }));
  const logPath = join(`${path}.events`, `${encodeURIComponent(session.id)}.jsonl`);
  await writeFile(logPath, `${await readFile(logPath, "utf8")}{"truncated":`, { mode: 0o600 });
  const recovered = new SessionStore(path);
  assert.equal((await recovered.get(session.id)).status, "idle");
  assert.equal((await recovered.events(session.id)).length, 2);
  await recovered.record(session.id, event(session.id, "status", { status: "running" }));
  const restarted = new SessionStore(path);
  assert.equal((await restarted.get(session.id)).status, "running");
  assert.equal((await restarted.events(session.id)).length, 3);
});

function event(sessionId, type, extra) {
  return { id: crypto.randomUUID(), sessionId, sequence: 999, timestamp: "2026-09-24T00:00:00.000Z", type, ...extra };
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail("condition was not met");
}

async function json(url, method, body, expectedStatus = 200) {
  const response = await fetch(url, {
    method,
    headers: body === undefined ? undefined : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  assert.equal(response.status, expectedStatus);
  return expectedStatus === 204 ? undefined : response.json();
}
