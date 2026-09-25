import assert from "node:assert/strict";
import test from "node:test";
import { ClaudeAdapter } from "../dist/index.js";

class EventStream {
  buffered = [];
  waiting = [];
  closed = false;
  push(value) {
    const resolve = this.waiting.shift();
    if (resolve) resolve({ done: false, value });
    else this.buffered.push(value);
  }
  close() {
    this.closed = true;
    for (const resolve of this.waiting.splice(0)) resolve({ done: true, value: undefined });
  }
  [Symbol.asyncIterator]() {
    return {
      next: async () => {
        if (this.buffered.length > 0) return { done: false, value: this.buffered.shift() };
        if (this.closed) return { done: true, value: undefined };
        return new Promise((resolve) => this.waiting.push(resolve));
      },
    };
  }
}

test("Claude adapter maps SDK streaming, tools, commands, completion, and resume", async () => {
  const requests = [];
  const streams = [];
  const native = [];
  const adapter = new ClaudeAdapter({
    query(request) {
      requests.push(request);
      const stream = new EventStream();
      streams.push(stream);
      return stream;
    },
    sessionExists: async () => true,
    onNativeEvent: (event) => native.push(event),
  });
  assert.deepEqual(adapter.capabilities(), { approvals: true, questions: true, resumeSession: true });
  const session = await adapter.createSession({
    sessionId: "11111111-1111-4111-8111-111111111111",
    projectId: "project-1",
    workingDirectory: "/project",
  });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  assert.equal((await events.next()).value.type, "session.started");

  await adapter.sendMessage(session.id, { content: "Run tests" });
  assert.equal((await events.next()).value.type, "message");
  assert.equal((await events.next()).value.status, "running");
  assert.equal(requests[0].resume, false);

  streams[0].push({
    type: "stream_event",
    parent_tool_use_id: null,
    event: { type: "content_block_delta", delta: { type: "text_delta", text: "Working" } },
  });
  streams[0].push({
    type: "assistant",
    parent_tool_use_id: null,
    message: { content: [
      { type: "text", text: "Working on it" },
      { type: "tool_use", id: "tool-1", name: "Bash", input: { command: "pnpm test" } },
    ] },
  });
  streams[0].push({
    type: "user",
    parent_tool_use_id: null,
    message: { content: [{ type: "tool_result", tool_use_id: "tool-1", content: "ok" }] },
    tool_use_result: null,
  });
  streams[0].push({ type: "result", subtype: "success", is_error: false, result: "Done" });
  streams[0].close();

  assert.equal((await events.next()).value.content, "Working");
  assert.equal((await events.next()).value.content, "Working on it");
  assert.equal((await events.next()).value.type, "tool.started");
  assert.equal((await events.next()).value.status, "started");
  assert.equal((await events.next()).value.output, null);
  assert.equal((await events.next()).value.status, "completed");
  assert.equal((await events.next()).value.status, "idle");
  assert.equal((await events.next()).value.outcome, "completed");

  await adapter.sendMessage(session.id, { content: "Continue" });
  assert.equal(requests[1].resume, true);
  assert.equal(requests[1].nativeSessionId, session.id);
  streams[1].push({ type: "result", subtype: "success", is_error: false, result: "Done again" });
  streams[1].close();
  assert.ok(native.length >= 4);
  await adapter.close();
});

test("Claude adapter maps permission requests and session approval suggestions", async () => {
  let permission;
  let permissionResult;
  const adapter = new ClaudeAdapter({
    query(request) {
      return (async function* () {
        permissionResult = await request.canUseTool("Bash", { command: "pnpm test" }, {
          signal: request.abortController.signal,
          toolUseID: "tool-approval",
          requestId: "request-1",
          title: "Run tests?",
          description: "Executes the test suite",
          suggestions: [{ type: "addRules", rules: [{ toolName: "Bash", ruleContent: "pnpm test" }], behavior: "allow", destination: "session" }],
        });
        yield { type: "result", subtype: "success", is_error: false, result: "Done" };
      })();
    },
  });
  const session = await adapter.createSession({ sessionId: "22222222-2222-4222-8222-222222222222", projectId: "p", workingDirectory: "/p" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await adapter.sendMessage(session.id, { content: "Test" });
  await events.next(); await events.next();
  permission = (await events.next()).value;
  assert.equal(permission.type, "approval.requested");
  assert.deepEqual(permission.actions, ["approve_once", "approve_session", "reject"]);
  assert.equal((await events.next()).value.status, "waiting_user");
  await adapter.respondToInteraction(session.id, permission.interactionId, { kind: "approval", action: "approve_session" });
  assert.equal((await events.next()).value.status, "running");
  await waitFor(() => permissionResult !== undefined);
  assert.equal(permissionResult.behavior, "allow");
  assert.equal(permissionResult.updatedPermissions.length, 1);
  await adapter.close();
});

test("Claude adapter maps multiple AskUserQuestion prompts and answers", async () => {
  let questionResult;
  const adapter = new ClaudeAdapter({
    query(request) {
      return (async function* () {
        questionResult = await request.canUseTool("AskUserQuestion", {
          questions: [
            { question: "Theme?", options: [{ label: "Light", description: "Bright" }, { label: "Dark" }] },
            { question: "Accent?", options: [{ label: "Blue" }, { label: "Green" }] },
          ],
        }, {
          signal: request.abortController.signal,
          toolUseID: "question-tool",
          requestId: "request-2",
        });
        yield { type: "result", subtype: "success", is_error: false, result: "Done" };
      })();
    },
  });
  const session = await adapter.createSession({ sessionId: "33333333-3333-4333-8333-333333333333", projectId: "p", workingDirectory: "/p" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await adapter.sendMessage(session.id, { content: "Ask" });
  await events.next(); await events.next();
  const first = (await events.next()).value;
  const second = (await events.next()).value;
  assert.equal(first.type, "question.requested");
  assert.equal(second.type, "question.requested");
  assert.equal((await events.next()).value.status, "waiting_user");
  await adapter.respondToInteraction(session.id, first.interactionId, { kind: "question", optionIds: ["0:1"] });
  await adapter.respondToInteraction(session.id, second.interactionId, { kind: "question", freeText: "Amber" });
  assert.equal((await events.next()).value.status, "running");
  await waitFor(() => questionResult !== undefined);
  assert.deepEqual(questionResult.updatedInput.answers, { "Theme?": "Dark", "Accent?": "Amber" });
  await adapter.close();
});

test("Claude adapter suppresses session approval when the SDK forbids a persistent choice", async () => {
  let finishPermission;
  const adapter = new ClaudeAdapter({
    query(request) {
      return (async function* () {
        finishPermission = request.canUseTool("Write", { file_path: "/p/file" }, {
          signal: request.abortController.signal,
          toolUseID: "sensitive-tool",
          requestId: "request-sensitive",
          suppressAlwaysAllowRule: true,
          suggestions: [{ type: "addRules", rules: [{ toolName: "Edit", ruleContent: "/p/**" }], behavior: "allow", destination: "localSettings" }],
        });
        await finishPermission;
        yield { type: "result", subtype: "success", is_error: false, result: "Done" };
      })();
    },
  });
  const session = await adapter.createSession({ sessionId: "77777777-7777-4777-8777-777777777777", projectId: "p", workingDirectory: "/p" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await adapter.sendMessage(session.id, { content: "Write" });
  await events.next(); await events.next();
  const approval = (await events.next()).value;
  assert.deepEqual(approval.actions, ["approve_once", "reject"]);
  await assert.rejects(
    adapter.respondToInteraction(session.id, approval.interactionId, { kind: "approval", action: "approve_session" }),
    /not available/,
  );
  await adapter.respondToInteraction(session.id, approval.interactionId, { kind: "approval", action: "reject" });
  await finishPermission;
  await adapter.close();
});

test("Claude adapter cancels an active SDK query", async () => {
  const adapter = new ClaudeAdapter({
    query(request) {
      return (async function* () {
        yield {
          type: "assistant",
          parent_tool_use_id: null,
          message: { content: [{ type: "tool_use", id: "active-bash", name: "Bash", input: { command: "sleep 60" } }] },
        };
        await new Promise((_, reject) => request.abortController.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true }));
        yield undefined;
      })();
    },
  });
  const session = await adapter.createSession({ sessionId: "44444444-4444-4444-8444-444444444444", projectId: "p", workingDirectory: "/p" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await adapter.sendMessage(session.id, { content: "Wait" });
  await events.next(); await events.next();
  assert.equal((await events.next()).value.type, "tool.started");
  assert.equal((await events.next()).value.status, "started");
  await adapter.cancel(session.id);
  assert.equal((await events.next()).value.type, "tool.finished");
  assert.equal((await events.next()).value.status, "failed");
  assert.equal((await events.next()).value.status, "idle");
  assert.equal((await events.next()).value.outcome, "cancelled");
  await adapter.close();
});

test("Claude adapter reports SDK failures and leaves the session reusable", async () => {
  const adapter = new ClaudeAdapter({
    query() {
      return (async function* () {
        yield { type: "result", subtype: "error_during_execution", is_error: true, errors: ["temporary failure"] };
      })();
    },
  });
  const session = await adapter.createSession({ sessionId: "55555555-5555-4555-8555-555555555555", projectId: "p", workingDirectory: "/p" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await adapter.sendMessage(session.id, { content: "Fail" });
  await events.next(); await events.next();
  const error = (await events.next()).value;
  assert.equal(error.code, "claude_turn_failed");
  assert.match(error.message, /temporary failure/);
  assert.equal((await events.next()).value.status, "idle");
  assert.equal((await events.next()).value.outcome, "failed");
  await waitFor(async () => {
    try { await adapter.sendMessage(session.id, { content: "Retry" }); return true; } catch { return false; }
  });
  await adapter.close();
});

test("Claude adapter records a synchronous query startup failure", async () => {
  const adapter = new ClaudeAdapter({ query() { throw new Error("spawn failed"); } });
  const session = await adapter.createSession({ sessionId: "66666666-6666-4666-8666-666666666666", projectId: "p", workingDirectory: "/p" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await assert.rejects(adapter.sendMessage(session.id, { content: "Start" }), /spawn failed/);
  await events.next(); await events.next();
  assert.equal((await events.next()).value.code, "claude_turn_start_failed");
  assert.equal((await events.next()).value.status, "idle");
  assert.equal((await events.next()).value.outcome, "failed");
  await adapter.close();
});

test("Claude adapter retries a first-turn asynchronous startup failure as a new native session", async () => {
  const requests = [];
  let attempt = 0;
  const adapter = new ClaudeAdapter({
    sessionExists: async () => false,
    query(request) {
      requests.push(request);
      attempt += 1;
      return (async function* () {
        if (attempt === 1) throw new Error("binary unavailable");
        yield { type: "result", subtype: "success", is_error: false, result: "Recovered" };
      })();
    },
  });
  const session = await adapter.createSession({ sessionId: "88888888-8888-4888-8888-888888888888", projectId: "p", workingDirectory: "/p" });
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await adapter.sendMessage(session.id, { content: "First" });
  await events.next(); await events.next();
  assert.equal((await events.next()).value.code, "claude_connection_lost");
  await events.next(); await events.next();
  await adapter.sendMessage(session.id, { content: "Retry" });
  assert.deepEqual(requests.map((request) => request.resume), [false, false]);
  await adapter.close();
});

test("Claude adapter checks persisted state before resuming in a new process", async () => {
  const resumedRequests = [];
  const existing = new ClaudeAdapter({
    sessionExists: async () => true,
    query(request) {
      resumedRequests.push(request);
      return (async function* () { yield { type: "result", subtype: "success", is_error: false, result: "Continued" }; })();
    },
  });
  const resumed = await existing.resumeSession("99999999-9999-4999-8999-999999999999", "/p");
  const resumedEvents = existing.events(resumed.id)[Symbol.asyncIterator]();
  await resumedEvents.next();
  await existing.sendMessage(resumed.id, { content: "Continue" });
  assert.equal(resumedRequests[0].resume, true);
  await existing.close();

  const freshRequests = [];
  const unstarted = new ClaudeAdapter({
    sessionExists: async () => false,
    query(request) {
      freshRequests.push(request);
      return (async function* () { yield { type: "result", subtype: "success", is_error: false, result: "Started" }; })();
    },
  });
  const restored = await unstarted.resumeSession("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "/p");
  const restoredEvents = unstarted.events(restored.id)[Symbol.asyncIterator]();
  await restoredEvents.next();
  await unstarted.sendMessage(restored.id, { content: "First real turn" });
  assert.equal(freshRequests[0].resume, false);
  await unstarted.close();
});

test("Claude adapter reserves a turn while checking persisted session state", async () => {
  let finishCheck;
  const checking = new Promise((resolve) => { finishCheck = resolve; });
  let requests = 0;
  const adapter = new ClaudeAdapter({
    sessionExists: async () => checking,
    query() {
      requests += 1;
      return (async function* () { yield { type: "result", subtype: "success", is_error: false, result: "Done" }; })();
    },
  });
  const session = await adapter.resumeSession("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "/p");
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  const first = adapter.sendMessage(session.id, { content: "First" });
  await assert.rejects(adapter.sendMessage(session.id, { content: "Second" }), /active turn/);
  finishCheck(true);
  await first;
  assert.equal(requests, 1);
  await adapter.close();
});

test("Claude adapter normalizes transcript probe failures", async () => {
  const adapter = new ClaudeAdapter({
    sessionExists: async () => { throw new Error("transcript unreadable"); },
  });
  const session = await adapter.resumeSession("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "/p");
  const events = adapter.events(session.id)[Symbol.asyncIterator]();
  await events.next();
  await assert.rejects(adapter.sendMessage(session.id, { content: "Continue" }), /transcript unreadable/);
  const error = (await events.next()).value;
  assert.equal(error.code, "claude_turn_start_failed");
  assert.equal((await events.next()).value.status, "idle");
  assert.equal((await events.next()).value.outcome, "failed");
  await adapter.close();
});

for (const toolName of ["Bash", "AskUserQuestion"]) {
  test(`Claude adapter does not hang when ${toolName} arrives after cancellation`, async () => {
    let callbackRejected = false;
    const adapter = new ClaudeAdapter({
      query(request) {
        return (async function* () {
          await new Promise((resolve) => request.abortController.signal.addEventListener("abort", resolve, { once: true }));
          const input = toolName === "AskUserQuestion"
            ? { questions: [{ question: "Continue?", options: [{ label: "Yes" }] }] }
            : { command: "pnpm test" };
          try {
            await request.canUseTool(toolName, input, {
              signal: request.abortController.signal,
              toolUseID: `late-${toolName}`,
              requestId: `request-${toolName}`,
            });
          } catch (error) {
            callbackRejected = error instanceof Error && error.name === "AbortError";
          }
          throw new DOMException("Aborted", "AbortError");
        })();
      },
    });
    const session = await adapter.createSession({ sessionId: crypto.randomUUID(), projectId: "p", workingDirectory: "/p" });
    const events = adapter.events(session.id)[Symbol.asyncIterator]();
    await events.next();
    await adapter.sendMessage(session.id, { content: "Cancel" });
    await events.next(); await events.next();
    await adapter.cancel(session.id);
    assert.equal(callbackRejected, true);
    assert.equal((await events.next()).value.status, "idle");
    assert.equal((await events.next()).value.outcome, "cancelled");
    await adapter.close();
  });
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail("condition was not met");
}
