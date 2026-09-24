import assert from "node:assert/strict";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { CodexAdapter, SpawnedCodexAppServer } from "../dist/index.js";

class FakeConnection {
  notifications = [];
  serverRequests = [];
  errors = [];
  requests = [];
  responses = [];
  responseErrors = [];
  failures = new Map();

  async start() {}
  async stop() {}
  onNotification(listener) { this.notifications.push(listener); }
  onServerRequest(listener) { this.serverRequests.push(listener); }
  onError(listener) { this.errors.push(listener); }
  respond(id, result) { this.responses.push({ id, result }); }
  respondError(id, code, message) { this.responseErrors.push({ id, code, message }); }
  async request(method, params) {
    this.requests.push({ method, params });
    if (this.failures.has(method)) throw this.failures.get(method);
    if (method === "thread/start") return { thread: { id: "thread-1" } };
    if (method === "thread/resume") return { thread: { id: params.threadId } };
    if (method === "turn/start") return { turn: { id: "turn-1" } };
    return {};
  }
  notify(method, params) { for (const listener of this.notifications) listener({ method, params }); }
  requestClient(method, id, params) { for (const listener of this.serverRequests) listener({ method, id, params }); }
  fail(error) { for (const listener of this.errors) listener(error); }
}

test("Codex adapter drives app-server and normalizes a turn with approval", async () => {
  const connection = new FakeConnection();
  let nextId = 0;
  const adapter = new CodexAdapter({
    connection,
    now: () => new Date("2026-09-24T00:00:00.000Z"),
    id: () => `event-${nextId++}`,
  });
  const session = await adapter.createSession({
    sessionId: "session-1",
    projectId: "project-1",
    workingDirectory: "/project",
  });
  assert.equal(session.nativeSessionId, "thread-1");
  assert.deepEqual(adapter.capabilities(), { approvals: true, questions: false, resumeSession: true });
  assert.deepEqual(connection.requests[0], {
    method: "thread/start",
    params: {
      cwd: "/project",
      approvalPolicy: "on-request",
      sandbox: "workspace-write",
      serviceName: "agentide",
      threadSource: "appServer",
    },
  });

  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  assert.equal((await events.next()).value.type, "session.started");
  await adapter.sendMessage(session.id, { content: "Run tests" });
  assert.equal((await events.next()).value.type, "message");
  assert.equal((await events.next()).value.type, "status");

  connection.notify("item/agentMessage/delta", { threadId: "thread-1", turnId: "turn-1", itemId: "item-1", delta: "Working" });
  connection.notify("item/started", { threadId: "thread-1", turnId: "turn-1", item: { type: "commandExecution", id: "cmd-1", command: "pnpm test", status: "inProgress" } });
  connection.requestClient("item/commandExecution/requestApproval", 42, { threadId: "thread-1", turnId: "turn-1", itemId: "cmd-1", command: "pnpm test", reason: "Run tests" });
  assert.equal((await events.next()).value.type, "text.delta");
  assert.equal((await events.next()).value.status, "started");
  const approval = (await events.next()).value;
  assert.equal(approval.type, "approval.requested");
  assert.equal(approval.interactionId, "42");
  assert.equal((await events.next()).value.status, "waiting_user");
  await adapter.respondToInteraction(session.id, "42", { kind: "approval", action: "approve_session" });
  assert.deepEqual(connection.responses, [{ id: 42, result: { decision: "acceptForSession" } }]);
  assert.equal((await events.next()).value.status, "running");

  connection.notify("item/completed", { threadId: "thread-1", turnId: "turn-1", item: { type: "agentMessage", id: "item-1", text: "Done" } });
  connection.notify("turn/completed", { threadId: "thread-1", turn: { id: "turn-1", status: "completed" } });
  assert.equal((await events.next()).value.content, "Done");
  assert.equal((await events.next()).value.status, "idle");
  const completed = (await events.next()).value;
  assert.equal(completed.type, "turn.completed");
  assert.equal(completed.outcome, "completed");
  assert.equal(completed.sequence, 10);
});

test("Codex adapter resumes a native thread and interrupts its active turn", async () => {
  const connection = new FakeConnection();
  const adapter = new CodexAdapter({ connection });
  const session = await adapter.resumeSession("thread-existing");
  await adapter.sendMessage(session.id, { content: "Continue" });
  await adapter.cancel(session.id);
  assert.deepEqual(connection.requests.map((request) => request.method), ["thread/resume", "turn/start", "turn/interrupt"]);
  assert.deepEqual(connection.requests.at(-1).params, { threadId: "thread-existing", turnId: "turn-1" });
});

test("Codex adapter honors approval choices and ignores unapplied file changes", async () => {
  const connection = new FakeConnection();
  const native = [];
  const adapter = new CodexAdapter({ connection, onNativeEvent: (event) => native.push(event) });
  const session = await adapter.createSession({ sessionId: "session-1", projectId: "project-1", workingDirectory: "/project" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  connection.requestClient("item/commandExecution/requestApproval", 7, {
    threadId: "thread-1", turnId: "turn-1", itemId: "cmd-1", availableDecisions: ["decline"],
  });
  const approval = (await events.next()).value;
  assert.deepEqual(approval.actions, ["reject"]);
  await events.next();
  connection.notify("item/completed", {
    threadId: "thread-1", turnId: "turn-1",
    item: { type: "fileChange", id: "file-1", status: "declined", changes: [{ path: "lost.txt", kind: { type: "add" }, diff: "" }] },
  });
  connection.notify("error", { threadId: "thread-1", error: { message: "temporary" }, willRetry: true });
  const error = (await events.next()).value;
  assert.equal(error.type, "error");
  assert.equal(error.message, "temporary");
  assert.equal(error.recoverable, true);
  assert.equal(native.length, 3);
});

test("Codex adapter reports unsupported requests and expands file moves", async () => {
  const connection = new FakeConnection();
  const adapter = new CodexAdapter({ connection });
  const session = await adapter.createSession({ sessionId: "session-1", projectId: "project-1", workingDirectory: "/project" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  connection.requestClient("account/chatgptAuthTokens/refresh", 8, {});
  assert.deepEqual(connection.responseErrors, [{ id: 8, code: -32601, message: "Unsupported Codex request: account/chatgptAuthTokens/refresh" }]);
  connection.notify("item/completed", {
    threadId: "thread-1", turnId: "turn-1",
    item: { type: "fileChange", id: "file-1", status: "completed", changes: [{ path: "/project/old.txt", kind: { type: "update", move_path: "/project/new.txt" }, diff: "" }] },
  });
  assert.deepEqual(
    [(await events.next()).value, (await events.next()).value].map(({ relativePath, change }) => ({ relativePath, change })),
    [{ relativePath: "old.txt", change: "deleted" }, { relativePath: "new.txt", change: "created" }],
  );
});

test("Codex adapter leaves a reusable session idle when turn start fails", async () => {
  const connection = new FakeConnection();
  connection.failures.set("turn/start", new Error("start rejected"));
  const adapter = new CodexAdapter({ connection });
  const session = await adapter.createSession({ sessionId: "session-1", projectId: "project-1", workingDirectory: "/project" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await assert.rejects(adapter.sendMessage(session.id, { content: "Try" }), /start rejected/);
  assert.equal((await events.next()).value.code, "codex_turn_start_failed");
  assert.equal((await events.next()).value.status, "idle");
  assert.equal((await events.next()).value.type, "turn.completed");
});

test("Codex adapter closes an active turn when the app-server connection is lost", async () => {
  const connection = new FakeConnection();
  const adapter = new CodexAdapter({ connection });
  const session = await adapter.createSession({ sessionId: "session-1", projectId: "project-1", workingDirectory: "/project" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await adapter.sendMessage(session.id, { content: "Run" });
  await events.next();
  await events.next();
  connection.fail(new Error("connection lost"));
  assert.equal((await events.next()).value.code, "codex_connection_lost");
  assert.equal((await events.next()).value.status, "idle");
  assert.equal((await events.next()).value.type, "turn.completed");
});

test("missing Codex executable rejects start without an unhandled child-process error", async () => {
  const connection = new SpawnedCodexAppServer("/definitely/missing/codex");
  await assert.rejects(connection.start(), /Unable to start Codex app-server/);
});

test("app-server can restart after initialize is rejected", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "agentide-codex-init-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const executable = join(directory, "fake-codex");
  const marker = join(directory, "initialized-once");
  await writeFile(executable, `#!/usr/bin/env node
const fs = require("node:fs");
const readline = require("node:readline");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  if (request.method !== "initialize") return;
  if (!fs.existsSync(process.env.INIT_MARKER)) {
    fs.writeFileSync(process.env.INIT_MARKER, "failed");
    process.stdout.write(JSON.stringify({ id: request.id, error: { code: -1, message: "init rejected" } }) + "\\n");
  } else {
    process.stdout.write(JSON.stringify({ id: request.id, result: {} }) + "\\n");
  }
});
`);
  await chmod(executable, 0o755);
  const connection = new SpawnedCodexAppServer(executable, { ...process.env, INIT_MARKER: marker });
  await assert.rejects(connection.start(), /init rejected/);
  await connection.start();
  await connection.stop();
});
