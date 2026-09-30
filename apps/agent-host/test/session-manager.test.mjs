import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createAgentHostServer, NotificationOutbox, ProjectStore, SessionManager, SessionStore } from "../dist/index.js";

class EventQueue {
  buffered = [];
  waiting = [];
  closed = false;
  push(value) {
    if (this.closed) return;
    const resolve = this.waiting.shift();
    if (resolve) resolve({ done: false, value });
    else this.buffered.push(value);
  }
  close() {
    this.closed = true;
    for (const resolve of this.waiting.splice(0)) resolve({ done: true, value: undefined });
  }
  [Symbol.asyncIterator]() {
    return { next: async () => this.buffered.length > 0 ? { done: false, value: this.buffered.shift() } : this.closed ? { done: true, value: undefined } : new Promise((resolve) => this.waiting.push(resolve)) };
  }
}

class FakeAdapter {
  queues = new Map();
  sent = [];
  resumed = [];
  interactions = [];
  constructor(type = "codex") { this.type = type; }
  capabilities() { return { approvals: true, questions: this.type === "claude", resumeSession: true }; }
  async createSession(options) {
    const queue = new EventQueue();
    this.queues.set(options.sessionId, queue);
    queue.push(event(options.sessionId, "session.started", { nativeSessionId: "native-1" }));
    return {
      id: options.sessionId,
      projectId: options.projectId,
      agentType: this.type,
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
      agentType: this.type,
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
  async close() { for (const queue of this.queues.values()) queue.close(); }
}

test("session manager starts every adapter shutdown without waiting for another adapter", async () => {
  let releaseFirst;
  let secondStarted = false;
  const first = new FakeAdapter("claude");
  first.close = () => new Promise((resolve) => { releaseFirst = resolve; });
  const second = new FakeAdapter("codex");
  second.close = async () => { secondStarted = true; };
  const manager = new SessionManager({}, {}, new Map([["claude", first], ["codex", second]]));

  const closing = manager.close();
  await Promise.resolve();
  assert.equal(secondStarted, true);
  releaseFirst();
  await closing;
});

test("session manager persists normalized events and resumes native sessions", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-sessions-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
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
    async snapshot(sessionId) { calls.push(["snapshot", sessionId]); return { session, recentEvents: [], pendingInteractions: [], latestSequence: 4, currentStatus: "running" }; },
    async create(input) { calls.push(["create", input]); return session; },
    async sendMessage(sessionId, input) { calls.push(["message", sessionId, input]); },
    async cancel(sessionId) { calls.push(["cancel", sessionId]); },
    async respond(sessionId, interactionId, response) { calls.push(["respond", sessionId, interactionId, response]); },
    async notificationPage(afterCursor, limit) { calls.push(["notificationPage", afterCursor, limit]); return { items: [], acknowledgedCursor: -1, latestCursor: -1, overflowed: false }; },
    async acknowledgeNotifications(cursor) { calls.push(["acknowledgeNotifications", cursor]); },
  };
  const server = createAgentHostServer(new ProjectStore("/unused", ""), sessions);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  const base = `http://127.0.0.1:${address.port}`;

  assert.equal((await json(`${base}/sessions`, "POST", { projectId: "project-1", agentType: "codex", initialPrompt: "Task" }, 201)).id, session.id);
  assert.equal((await json(`${base}/sessions?projectId=project-1`, "GET")).sessions.length, 1);
  assert.equal((await json(`${base}/sessions/session-1`, "GET")).id, session.id);
  assert.deepEqual(await json(`${base}/sessions/session-1/snapshot`, "GET"), {
    session,
    recentEvents: [],
    pendingInteractions: [],
    latestSequence: 4,
    currentStatus: "running",
  });
  assert.deepEqual(calls.at(-1), ["snapshot", "session-1"]);
  assert.equal((await json(`${base}/sessions/session-1/events?afterSequence=2`, "GET")).events.length, 1);
  await json(`${base}/sessions/session-1/messages`, "POST", { content: "Continue" }, 204);
  await json(`${base}/sessions/session-1/cancel`, "POST", {}, 204);
  await json(`${base}/sessions/session-1/interactions`, "POST", { kind: "approval", interactionId: "42", action: "approve_once" }, 204);
  assert.deepEqual(calls.at(-1), ["respond", "session-1", "42", { kind: "approval", action: "approve_once" }]);
  await json(`${base}/sessions/session-1/interactions`, "POST", { kind: "question", interactionId: "q1", optionIds: ["option-1"], freeText: "details" }, 204);
  assert.deepEqual(calls.at(-1), ["respond", "session-1", "q1", { kind: "question", optionIds: ["option-1"], freeText: "details" }]);
  assert.deepEqual(await json(`${base}/notifications/outbox?afterCursor=2&limit=10`, "GET"), {
    items: [], acknowledgedCursor: -1, latestCursor: -1, overflowed: false,
  });
  assert.deepEqual(calls.at(-1), ["notificationPage", 2, 10]);
  await json(`${base}/notifications/outbox/ack`, "POST", { cursor: 3 }, 204);
  assert.deepEqual(calls.at(-1), ["acknowledgeNotifications", 3]);
});

test("notification outbox persists minimal intents, deduplicates events, and reports bounded overflow", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-notification-outbox-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  const path = join(base, "notifications.json");
  const outbox = new NotificationOutbox(path, 2);
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Fix tests", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  const approval = event(session.id, "approval.requested", { interactionId: "approval-1", title: "Sensitive command", actions: ["reject"] });
  approval.sequence = 4;
  await outbox.enqueue(session, approval);
  await outbox.enqueue(session, approval);
  const question = event(session.id, "question.requested", { interactionId: "question-1", question: "Sensitive question", allowFreeText: true });
  question.sequence = 5;
  await outbox.enqueue(session, question);
  const completed = event(session.id, "turn.completed", { outcome: "completed" });
  completed.sequence = 6;
  await outbox.enqueue(session, completed);

  const page = await new NotificationOutbox(path, 2).page();
  assert.equal(page.items.length, 2);
  assert.deepEqual(page.items.map((item) => item.category), ["question_waiting", "task_completed"]);
  assert.equal(page.overflowed, true);
  assert.equal(page.droppedThroughCursor, 0);
  assert.equal(JSON.stringify(page).includes("Sensitive"), false);
  await outbox.acknowledge(page.items[0].cursor);
  assert.deepEqual((await outbox.page()).items.map((item) => item.category), ["task_completed"]);
});

test("session event persistence feeds the notification outbox without a remote event subscriber", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-notification-session-store-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  const outbox = new NotificationOutbox(join(base, "notifications.json"));
  const store = new SessionStore(join(base, "sessions.json"), outbox);
  const session = { id: "session-offline", projectId: "project-1", agentType: "codex", title: "Offline task", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  await store.create(session);
  await store.record(session.id, event(session.id, "approval.requested", {
    interactionId: "approval-offline", title: "Approve", actions: ["reject"],
  }));
  await waitFor(async () => (await store.notificationPage()).items.length === 1);

  const page = await store.notificationPage();
  assert.equal(page.items[0].category, "approval_waiting");
  assert.equal(page.items[0].sessionId, session.id);
  assert.equal((await store.events(session.id)).length, 1);
});

test("slow notification persistence does not block authoritative events in other sessions", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-notification-nonblocking-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let calls = 0;
  const outbox = {
    async reconcile() { calls += 1; if (calls === 1) await gate; },
    async page() { return { items: [], acknowledgedCursor: -1, latestCursor: -1, overflowed: false }; },
    async acknowledge() {},
  };
  const store = new SessionStore(join(base, "sessions.json"), outbox);
  const first = { id: "session-1", projectId: "project-1", agentType: "codex", title: "First", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  const second = { ...first, id: "session-2", title: "Second" };
  await store.create(first);
  await store.create(second);
  await store.record(first.id, event(first.id, "approval.requested", { interactionId: "approval-1", title: "Approve", actions: ["reject"] }));
  await store.record(second.id, event(second.id, "status", { status: "running" }));
  assert.equal((await store.events(second.id)).length, 1);
  release();
  await store.flushNotifications();
});

test("blocked notification writes coalesce text deltas without delaying their event log", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-notification-coalescing-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let calls = 0;
  const outbox = {
    async reconcile() { calls += 1; if (calls === 1) await gate; },
    async page() { return { items: [], acknowledgedCursor: -1, latestCursor: -1, overflowed: false }; },
    async acknowledge() {},
  };
  const store = new SessionStore(join(base, "sessions.json"), outbox);
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Streaming", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  await store.create(session);
  for (let index = 0; index < 250; index += 1) {
    await store.record(session.id, event(session.id, "text.delta", { content: `${index}` }));
  }
  assert.equal((await store.events(session.id)).length, 250);
  assert.equal(calls, 1);
  release();
  await store.flushNotifications();
  assert.ok(calls <= 2);
});

test("blocked notification writes retain a bounded session range and derive every notification", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-notification-range-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let calls = 0;
  let largestBatch = 0;
  const durableOutbox = new NotificationOutbox(join(base, "notifications.json"), 300);
  const outbox = {
    async reconcile(sessions, events) {
      calls += 1;
      largestBatch = Math.max(largestBatch, ...Object.values(events).map((values) => values.length));
      if (calls === 1) await gate;
      await durableOutbox.reconcile(sessions, events);
    },
    async page(...args) { return durableOutbox.page(...args); },
    async acknowledge(...args) { return durableOutbox.acknowledge(...args); },
  };
  const store = new SessionStore(join(base, "sessions.json"), outbox);
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Busy", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  await store.create(session);
  for (let index = 0; index < 900; index += 1) {
    if (index % 3 === 0) {
      await store.record(session.id, event(session.id, "approval.requested", {
        interactionId: `approval-${index}`, title: "Approve", actions: ["reject"],
      }));
    } else if (index % 3 === 1) {
      await store.record(session.id, event(session.id, "question.requested", {
        interactionId: `question-${index}`, question: "Continue?", allowFreeText: true,
      }));
    } else {
      await store.record(session.id, event(session.id, "turn.completed", { outcome: "completed" }));
    }
  }
  assert.equal((await store.events(session.id)).length, 900);
  assert.equal(calls, 1);
  release();
  await store.flushNotifications();
  const page = await durableOutbox.page(undefined, 300);
  assert.equal(page.items.length, 300);
  assert.deepEqual(new Set(page.items.map((item) => item.category)), new Set([
    "approval_waiting", "question_waiting", "task_completed",
  ]));
  assert.ok(calls <= 5);
  assert.ok(largestBatch <= 256);
});

test("a restarted session store rebuilds notification gaps from the authoritative event log", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-notification-recovery-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  const sessionPath = join(base, "sessions.json");
  const failedOutbox = {
    async reconcile() { throw new Error("outbox unavailable"); },
    async page() { return { items: [], acknowledgedCursor: -1, latestCursor: -1, overflowed: false }; },
    async acknowledge() {},
  };
  const store = new SessionStore(sessionPath, failedOutbox);
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Recover me", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  await store.create(session);
  await store.record(session.id, event(session.id, "question.requested", { interactionId: "question-1", question: "Continue?", allowFreeText: true }));
  await assert.rejects(store.flushNotifications(), /outbox unavailable/);

  const restarted = new SessionStore(sessionPath, new NotificationOutbox(join(base, "notifications.json")));
  const page = await restarted.notificationPage();
  assert.deepEqual(page.items.map((item) => [item.sessionId, item.category]), [[session.id, "question_waiting"]]);
});

test("notification recovery reads a large authoritative log in bounded batches", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-notification-bounded-recovery-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  const sessionPath = join(base, "sessions.json");
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Recover many", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  const events = Array.from({ length: 1_200 }, (_, sequence) => ({
    ...event(session.id, "turn.completed", { outcome: "completed" }),
    sequence,
  }));
  await writeFile(sessionPath, `${JSON.stringify({ sessions: [session], resolvedInteractions: {} })}\n`);
  const eventDirectory = `${sessionPath}.events`;
  await mkdir(eventDirectory);
  await writeFile(join(eventDirectory, `${encodeURIComponent(session.id)}.jsonl`), `${events.map((value) => JSON.stringify(value)).join("\n")}\n`);

  const durableOutbox = new NotificationOutbox(join(base, "notifications.json"), 100);
  let largestBatch = 0;
  const outbox = {
    async reconcile(sessions, eventsBySession) {
      largestBatch = Math.max(largestBatch, ...Object.values(eventsBySession).map((values) => values.length));
      await durableOutbox.reconcile(sessions, eventsBySession);
    },
    async page(...args) { return durableOutbox.page(...args); },
    async acknowledge(...args) { return durableOutbox.acknowledge(...args); },
  };
  const store = new SessionStore(sessionPath, outbox);
  const page = await store.notificationPage(undefined, 200);

  assert.ok(largestBatch <= 256);
  assert.equal(page.items.length, 100);
  assert.equal(page.items[0].sequence, 1_100);
  assert.equal(page.items.at(-1).sequence, 1_199);
  assert.equal(page.overflowed, true);
});

test("session manager persists and expires Claude questions through the shared interaction boundary", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-claude-sessions-"));
  const managers = [];
  context.after(async () => {
    await Promise.all(managers.map((manager) => manager.close()));
    await rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 });
  });
  const root = join(base, "project");
  await mkdir(root);
  const projects = new ProjectStore(join(base, "projects.json"), "");
  const project = await projects.add(root);
  const sessionPath = join(base, "sessions.json");
  const adapter = new FakeAdapter("claude");
  const manager = new SessionManager(projects, new SessionStore(sessionPath), new Map([["claude", adapter]]));
  managers.push(manager);
  const session = await manager.create({ projectId: project.id, agentType: "claude", initialPrompt: "Ask me" });
  await waitFor(async () => (await manager.events(session.id)).some((value) => value.type === "status"));
  adapter.queues.get(session.id).push(event(session.id, "question.requested", {
    interactionId: "question-1",
    question: "Theme?",
    options: [{ id: "dark", label: "Dark" }],
    allowFreeText: true,
  }));
  adapter.queues.get(session.id).push(event(session.id, "status", { status: "waiting_user" }));
  await waitFor(async () => (await manager.get(session.id)).status === "waiting_user");

  const resumedAdapter = new FakeAdapter("claude");
  const restarted = new SessionManager(projects, new SessionStore(sessionPath), new Map([["claude", resumedAdapter]]));
  managers.push(restarted);
  await assert.rejects(
    restarted.respond(session.id, "question-1", { kind: "question", optionIds: ["dark"] }),
    /Interaction expired/,
  );
  assert.ok((await restarted.events(session.id)).some((value) => value.code === "agent_interaction_expired"));
});

test("session store does not expose a mutation when atomic persistence fails", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-store-failure-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
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
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  const path = join(base, "sessions.json");
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Task", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  const store = new SessionStore(path);
  await store.create(session);
  await store.record(session.id, event(session.id, "approval.requested", { interactionId: "42", title: "Approve", actions: ["reject"] }));
  assert.equal((await new SessionStore(path).get(session.id)).status, "waiting_user");
  await store.record(session.id, event(session.id, "question.requested", { interactionId: "q1", question: "Choose", allowFreeText: true }));
  assert.equal((await new SessionStore(path).get(session.id)).status, "waiting_user");
  await store.record(session.id, event(session.id, "turn.completed", { outcome: "failed" }));
  const logPath = join(`${path}.events`, `${encodeURIComponent(session.id)}.jsonl`);
  await writeFile(logPath, `${await readFile(logPath, "utf8")}{"truncated":`, { mode: 0o600 });
  const recovered = new SessionStore(path);
  assert.equal((await recovered.get(session.id)).status, "idle");
  assert.equal((await recovered.events(session.id)).length, 3);
  await recovered.record(session.id, event(session.id, "status", { status: "running" }));
  const restarted = new SessionStore(path);
  assert.equal((await restarted.get(session.id)).status, "running");
  assert.equal((await restarted.events(session.id)).length, 4);
});

test("session store preserves report payloads and assigns stable sequences across restart", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-store-report-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  const path = join(base, "sessions.json");
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Task", status: "running", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  const store = new SessionStore(path);
  await store.create(session);
  const stored = await store.record(session.id, event(session.id, "report", {
    reportVersion: 1,
    reportId: "tests-1",
    kind: "test_report",
    title: "Tests",
    summary: "One test passed",
    payload: { total: 1, passed: 1, failed: 0, skipped: 0, failures: [] },
  }));
  assert.equal(stored.sequence, 0);

  const restarted = new SessionStore(path);
  const [report] = await restarted.events(session.id);
  assert.equal(report.sequence, 0);
  assert.equal(report.type, "report");
  assert.deepEqual(report.payload, { total: 1, passed: 1, failed: 0, skipped: 0, failures: [] });

  const next = await restarted.record(session.id, event(session.id, "message", { role: "agent", content: "done", format: "plain" }));
  assert.equal(next.sequence, 1);
});

test("session snapshots bound event history and retain each unresolved interaction", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-session-snapshot-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  const root = join(base, "project");
  await mkdir(root);
  const projects = new ProjectStore(join(base, "projects.json"), "");
  const project = await projects.add(root);
  const store = new SessionStore(join(base, "sessions.json"));
  const session = { id: "session-1", projectId: project.id, agentType: "codex", nativeSessionId: "native-1", title: "Task", status: "idle", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  await store.create(session);
  const adapter = new FakeAdapter();
  const manager = new SessionManager(projects, store, new Map([["codex", adapter]]));
  await manager.get(session.id);
  for (let index = 0; index < 201; index += 1) {
    await store.record(session.id, event(session.id, "message", { role: "agent", content: `${index}`, format: "plain" }));
  }
  await store.record(session.id, event(session.id, "approval.requested", { interactionId: "approval-1", title: "Approve", actions: ["reject"] }));
  const waiting = await manager.snapshot(session.id);
  assert.equal(waiting.recentEvents.length, 200);
  assert.equal(waiting.recentEvents[0].sequence, 2);
  assert.equal(waiting.latestSequence, 201);
  assert.equal(waiting.currentStatus, "waiting_user");
  assert.deepEqual(waiting.pendingInteractions.map((interaction) => interaction.interactionId), ["approval-1"]);

  await store.record(session.id, event(session.id, "question.requested", { interactionId: "question-1", question: "Continue?", allowFreeText: true }));
  await store.record(session.id, event(session.id, "question.requested", { interactionId: "question-2", question: "Proceed?", allowFreeText: true }));
  await manager.respond(session.id, "question-1", { kind: "question", freeText: "Yes" });
  assert.deepEqual((await manager.snapshot(session.id)).pendingInteractions.map((interaction) => interaction.interactionId), ["approval-1", "question-2"]);
  assert.deepEqual(adapter.interactions, [{ sessionId: "native-1", interactionId: "question-1", response: { kind: "question", freeText: "Yes" } }]);

  await store.record(session.id, event(session.id, "status", { status: "running" }));
  const restarted = new SessionManager(projects, new SessionStore(join(base, "sessions.json")), new Map([["codex", new FakeAdapter()]]));
  assert.deepEqual((await restarted.snapshot(session.id)).pendingInteractions, []);

  await store.record(session.id, event(session.id, "question.requested", { interactionId: "question-1", question: "Continue again?", allowFreeText: true }));
  assert.deepEqual((await manager.snapshot(session.id)).pendingInteractions.map((interaction) => interaction.interactionId), ["question-1"]);
  const persistedSnapshot = await new SessionStore(join(base, "sessions.json")).snapshot(session.id);
  assert.ok(persistedSnapshot);
  assert.equal(persistedSnapshot.resolvedInteractionSequences.get("question-1")?.has(202), true);
  assert.equal(persistedSnapshot.resolvedInteractionSequences.get("question-1")?.has(205), false);
});

test("first snapshot reconciles a later interaction generation from stale resolved metadata", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-stale-interaction-metadata-"));
  const managers = [];
  context.after(async () => {
    await Promise.all(managers.map((manager) => manager.close()));
    await rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 });
  });
  const root = join(base, "project");
  await mkdir(root);
  const projects = new ProjectStore(join(base, "projects.json"), "");
  const project = await projects.add(root);
  const path = join(base, "sessions.json");
  const store = new SessionStore(path);
  const session = { id: "session-1", projectId: project.id, agentType: "codex", nativeSessionId: "native-1", title: "Task", status: "idle", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  await store.create(session);
  await store.record(session.id, event(session.id, "approval.requested", { interactionId: "repeat", title: "First", actions: ["reject"] }));
  await store.resolveInteraction(session.id, "repeat");
  const staleMetadata = await readFile(path, "utf8");
  await store.record(session.id, event(session.id, "status", { status: "running" }));
  await store.record(session.id, event(session.id, "approval.requested", { interactionId: "repeat", title: "Second", actions: ["reject"] }));

  await writeFile(path, staleMetadata, { mode: 0o600 });
  const reloaded = new SessionStore(path);
  const snapshot = await reloaded.snapshot(session.id);
  assert.ok(snapshot);
  assert.equal(snapshot.resolvedInteractionSequences.get("repeat")?.has(0), true);
  const manager = new SessionManager(projects, reloaded, new Map([["codex", new FakeAdapter()]]));
  managers.push(manager);
  assert.deepEqual((await manager.snapshot(session.id)).pendingInteractions, []);
  assert.equal((await manager.get(session.id)).status, "idle");
  assert.ok((await manager.events(session.id)).some((value) => value.code === "agent_interaction_expired"));
  const reconciled = await reloaded.snapshot(session.id);
  assert.ok(reconciled);
  assert.equal(reconciled.resolvedInteractionSequences.get("repeat")?.has(2), true);
});

test("resolved interaction generations accumulate for a repeated interaction id", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-resolved-interaction-generations-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  const root = join(base, "project");
  await mkdir(root);
  const projects = new ProjectStore(join(base, "projects.json"), "");
  const project = await projects.add(root);
  const store = new SessionStore(join(base, "sessions.json"));
  const session = { id: "session-1", projectId: project.id, agentType: "codex", nativeSessionId: "native-1", title: "Task", status: "idle", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  await store.create(session);
  const manager = new SessionManager(projects, store, new Map([["codex", new FakeAdapter()]]));
  await manager.get(session.id);

  await store.record(session.id, event(session.id, "approval.requested", { interactionId: "repeat", title: "First", actions: ["reject"] }));
  await store.resolveInteraction(session.id, "repeat");
  await store.record(session.id, event(session.id, "approval.requested", { interactionId: "repeat", title: "Second", actions: ["reject"] }));
  await store.resolveInteraction(session.id, "repeat");

  const snapshot = await store.snapshot(session.id);
  assert.ok(snapshot);
  assert.equal(snapshot.resolvedInteractionSequences.get("repeat")?.has(0), true);
  assert.equal(snapshot.resolvedInteractionSequences.get("repeat")?.has(1), true);
  assert.deepEqual((await manager.snapshot(session.id)).pendingInteractions, []);
});

test("session store snapshots do not tear session state from events", async (context) => {
  const base = await mkdtemp(join(tmpdir(), "agentide-snapshot-consistency-"));
  context.after(() => rm(base, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 }));
  const store = new SessionStore(join(base, "sessions.json"));
  const session = { id: "session-1", projectId: "project-1", agentType: "codex", title: "Task", status: "starting", createdAt: "2026-09-24T00:00:00.000Z", updatedAt: "2026-09-24T00:00:00.000Z" };
  await store.create(session);
  await store.events(session.id);

  const recording = store.record(session.id, event(session.id, "status", { status: "running" }));
  await Promise.resolve();
  const snapshot = await store.snapshot(session.id);
  await recording;

  assert.ok(snapshot);
  assert.equal(snapshot.events.length, 1);
  assert.equal(snapshot.events[0].sequence, 0);
  assert.equal(snapshot.session.status, "running");
  assert.equal(snapshot.session.updatedAt, snapshot.events[0].timestamp);
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
