import type {
  AgentAdapter,
  AgentEvent,
  AgentInput,
  AgentSession,
  ApprovalAction,
  CreateSessionOptions,
  InteractionResponse,
} from "@agentide/agent-core";
import { isAbsolute, relative, resolve, sep } from "node:path";
import type { CodexAppServerConnection, CodexNotification, CodexServerRequest } from "./app-server.js";
import { SpawnedCodexAppServer } from "./app-server.js";

interface SessionState {
  session: AgentSession;
  threadId: string;
  workingDirectory: string | undefined;
  activeTurnId?: string;
  turnStarting: boolean;
  loaded: boolean;
  loading?: Promise<void>;
  nextSequence: number;
  events: AsyncEventQueue;
  pendingInteractions: Map<string, PendingInteraction>;
}

interface PendingInteraction {
  requestId: string | number;
  kind: "command" | "file";
  actions: ApprovalAction[];
  rejectDecision: "decline" | "cancel";
}

export interface CodexAdapterOptions {
  connection?: CodexAppServerConnection;
  now?: () => Date;
  id?: () => string;
  onNativeEvent?: (event: CodexNotification | CodexServerRequest) => void;
}

export class CodexAdapter implements AgentAdapter {
  readonly type = "codex" as const;
  private readonly connection: CodexAppServerConnection;
  private readonly now: () => Date;
  private readonly id: () => string;
  private readonly onNativeEvent: (event: CodexNotification | CodexServerRequest) => void;
  private readonly sessions = new Map<string, SessionState>();
  private readonly sessionByThread = new Map<string, SessionState>();
  private started = false;

  constructor(options: CodexAdapterOptions = {}) {
    this.connection = options.connection ?? new SpawnedCodexAppServer();
    this.now = options.now ?? (() => new Date());
    this.id = options.id ?? (() => crypto.randomUUID());
    this.onNativeEvent = options.onNativeEvent ?? (() => undefined);
    this.connection.onNotification((notification) => this.handleNotification(notification));
    this.connection.onServerRequest((request) => this.handleServerRequest(request));
    this.connection.onError((error) => this.handleConnectionError(error));
  }

  capabilities() {
    return { approvals: true, questions: false, resumeSession: true };
  }

  async createSession(options: CreateSessionOptions): Promise<AgentSession> {
    await this.ensureStarted();
    const result = await this.connection.request("thread/start", {
      cwd: options.workingDirectory,
      approvalPolicy: "on-request",
      sandbox: "workspace-write",
      serviceName: "agentide",
      threadSource: "appServer",
    });
    const threadId = readNestedString(result, "thread", "id");
    const timestamp = this.now().toISOString();
    const session: AgentSession = {
      id: options.sessionId,
      projectId: options.projectId,
      agentType: "codex",
      nativeSessionId: threadId,
      title: titleFor(options.initialPrompt),
      status: "starting",
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    const state = this.register(session, threadId, true, options.workingDirectory);
    this.emit(state, { type: "session.started", nativeSessionId: threadId });
    return { ...state.session };
  }

  async resumeSession(nativeSessionId: string, workingDirectory?: string): Promise<AgentSession> {
    await this.ensureStarted();
    const existing = this.sessionByThread.get(nativeSessionId);
    if (existing !== undefined) return { ...existing.session };
    const result = await this.connection.request("thread/resume", { threadId: nativeSessionId, excludeTurns: true });
    const threadId = readNestedString(result, "thread", "id");
    const timestamp = this.now().toISOString();
    const session: AgentSession = {
      id: nativeSessionId,
      projectId: "",
      agentType: "codex",
      nativeSessionId: threadId,
      title: "Codex session",
      status: "idle",
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    const state = this.register(session, threadId, true, workingDirectory);
    this.emit(state, { type: "session.started", nativeSessionId: threadId });
    return { ...state.session };
  }

  async sendMessage(sessionId: string, input: AgentInput): Promise<void> {
    const state = this.requireSession(sessionId);
    await this.ensureLoaded(state);
    if (state.activeTurnId !== undefined || state.turnStarting) throw new Error("Codex session already has an active turn");
    if (input.attachments !== undefined && input.attachments.length > 0) throw new Error("Codex attachments are not supported yet");
    state.turnStarting = true;
    try {
      const result = await this.connection.request("turn/start", {
        threadId: state.threadId,
        input: [{ type: "text", text: input.content, text_elements: [] }],
      });
      state.activeTurnId = readNestedString(result, "turn", "id");
      state.session.status = "running";
      state.session.updatedAt = this.now().toISOString();
      this.emit(state, { type: "message", role: "user", content: input.content, format: "plain" });
      this.emit(state, { type: "status", status: "running" });
    } catch (error) {
      state.session.status = "idle";
      state.session.updatedAt = this.now().toISOString();
      this.emit(state, {
        type: "error",
        code: "codex_turn_start_failed",
        message: error instanceof Error ? error.message : "Codex turn failed to start",
        recoverable: true,
      });
      this.emit(state, { type: "status", status: "idle" });
      this.emit(state, { type: "turn.completed", outcome: "failed" });
      throw error;
    } finally {
      state.turnStarting = false;
    }
  }

  async cancel(sessionId: string): Promise<void> {
    const state = this.requireSession(sessionId);
    await this.ensureLoaded(state);
    if (state.activeTurnId === undefined) return;
    await this.connection.request("turn/interrupt", { threadId: state.threadId, turnId: state.activeTurnId });
  }

  async respondToInteraction(sessionId: string, interactionId: string, response: InteractionResponse): Promise<void> {
    const state = this.requireSession(sessionId);
    await this.ensureLoaded(state);
    const pending = state.pendingInteractions.get(interactionId);
    if (pending === undefined) throw new Error("Interaction is not pending");
    if (response.kind !== "approval") throw new Error("Codex interaction requires an approval response");
    if (!pending.actions.includes(response.action)) throw new Error("Approval action is not available");
    this.connection.respond(pending.requestId, { decision: decisionFor(response.action, pending.rejectDecision) });
    state.pendingInteractions.delete(interactionId);
    state.session.status = state.pendingInteractions.size === 0 ? "running" : "waiting_user";
    state.session.updatedAt = this.now().toISOString();
    this.emit(state, { type: "status", status: state.session.status });
  }

  events(sessionId: string): AsyncIterable<AgentEvent> {
    return this.requireSession(sessionId).events;
  }

  private async ensureStarted(): Promise<void> {
    if (this.started) return;
    await this.connection.start();
    this.started = true;
  }

  async close(): Promise<void> {
    await this.connection.stop();
    for (const state of this.sessions.values()) state.events.close();
    this.sessions.clear();
    this.sessionByThread.clear();
  }

  private register(session: AgentSession, threadId: string, loaded: boolean, workingDirectory?: string): SessionState {
    const existing = this.sessionByThread.get(threadId);
    if (existing !== undefined) {
      this.sessions.set(session.id, existing);
      existing.loaded ||= loaded;
      existing.workingDirectory ??= workingDirectory;
      return existing;
    }
    const state: SessionState = {
      session,
      threadId,
      workingDirectory,
      nextSequence: 0,
      turnStarting: false,
      loaded,
      events: new AsyncEventQueue(),
      pendingInteractions: new Map(),
    };
    this.sessions.set(session.id, state);
    this.sessionByThread.set(threadId, state);
    return state;
  }

  private requireSession(sessionId: string): SessionState {
    const state = this.sessions.get(sessionId);
    if (state === undefined) throw new Error(`Codex session is not loaded: ${sessionId}`);
    return state;
  }

  private handleNotification(notification: CodexNotification): void {
    this.captureNativeEvent(notification);
    const params = asRecord(notification.params);
    const threadId = readString(params, "threadId", false);
    if (threadId === undefined) return;
    const state = this.sessionByThread.get(threadId);
    if (state === undefined) return;
    if (notification.method === "turn/started") {
      state.activeTurnId = readString(asRecord(params.turn), "id");
      return;
    }
    if (notification.method === "item/agentMessage/delta") {
      const delta = readString(params, "delta", false);
      if (delta !== undefined) this.emit(state, { type: "text.delta", content: delta });
      return;
    }
    if (notification.method === "item/started" || notification.method === "item/completed") {
      this.handleItem(state, asRecord(params.item), notification.method === "item/completed");
      return;
    }
    if (notification.method === "turn/completed") {
      const turn = asRecord(params.turn);
      const status = readString(turn, "status");
      delete state.activeTurnId;
      state.turnStarting = false;
      state.pendingInteractions.clear();
      const outcome = status === "interrupted" ? "cancelled" : status === "failed" ? "failed" : "completed";
      state.session.status = "idle";
      state.session.updatedAt = this.now().toISOString();
      if (status === "failed") {
        const error = asOptionalRecord(turn.error);
        this.emit(state, {
          type: "error",
          code: "codex_turn_failed",
          message: error === undefined ? "Codex turn failed" : readString(error, "message"),
          recoverable: true,
        });
      }
      this.emit(state, { type: "status", status: "idle" });
      this.emit(state, { type: "turn.completed", outcome });
      return;
    }
    if (notification.method === "error") {
      const error = asOptionalRecord(params.error);
      this.emit(state, {
        type: "error",
        code: "codex_error",
        message: error === undefined ? "Codex app-server error" : readString(error, "message", false) ?? "Codex app-server error",
        recoverable: params.willRetry === true,
      });
    }
  }

  private handleItem(state: SessionState, item: Record<string, unknown>, completed: boolean): void {
    const type = readString(item, "type", false);
    if (type === "agentMessage" && completed) {
      this.emit(state, { type: "message", role: "agent", content: readString(item, "text"), format: "markdown" });
      return;
    }
    if (type === "commandExecution") {
      const status = readString(item, "status");
      const mappedStatus = status === "inProgress" ? "started" : status === "completed" ? "completed" : "failed";
      const event: CommandEventInput = { type: "command", command: readString(item, "command"), status: mappedStatus };
      if (typeof item.exitCode === "number") event.exitCode = item.exitCode;
      this.emit(state, event);
      return;
    }
    if (type === "fileChange" && completed) {
      if (readString(item, "status") !== "completed") return;
      const changes = Array.isArray(item.changes) ? item.changes : [];
      for (const changeValue of changes) {
        const change = asRecord(changeValue);
        const kind = asRecord(change.kind);
        const changeType = readString(kind, "type");
        const relativePath = projectRelativePath(readString(change, "path"), state.workingDirectory);
        if (relativePath === undefined) continue;
        const movePathValue = readString(kind, "move_path", false);
        const movePath = movePathValue === undefined ? undefined : projectRelativePath(movePathValue, state.workingDirectory);
        if (changeType === "update" && movePath !== undefined) {
          this.emit(state, { type: "file.changed", relativePath, change: "deleted" });
          this.emit(state, { type: "file.changed", relativePath: movePath, change: "created" });
        } else {
          this.emit(state, {
            type: "file.changed",
            relativePath,
            change: changeType === "add" ? "created" : changeType === "delete" ? "deleted" : "modified",
          });
        }
      }
      return;
    }
    if (type === "mcpToolCall") {
      const toolName = `${readString(item, "server")}.${readString(item, "tool")}`;
      if (!completed) this.emit(state, { type: "tool.started", toolName, input: item.arguments });
      else {
        const error = asOptionalRecord(item.error);
        const event: ToolFinishedEventInput = { type: "tool.finished", toolName, output: item.result };
        if (error !== undefined) event.error = readString(error, "message", false) ?? "Tool failed";
        this.emit(state, event);
      }
    }
  }

  private handleServerRequest(request: CodexServerRequest): void {
    this.captureNativeEvent(request);
    if (request.method !== "item/commandExecution/requestApproval" && request.method !== "item/fileChange/requestApproval") {
      this.connection.respondError(request.id, -32601, `Unsupported Codex request: ${request.method}`);
      return;
    }
    const params = asRecord(request.params);
    const state = this.sessionByThread.get(readString(params, "threadId"));
    if (state === undefined) {
      this.connection.respond(request.id, { decision: "decline" });
      return;
    }
    const interactionId = String(request.id);
    const kind = request.method.includes("commandExecution") ? "command" : "file";
    const available = Array.isArray(params.availableDecisions) ? params.availableDecisions : undefined;
    const actions = approvalActions(available);
    state.pendingInteractions.set(interactionId, {
      requestId: request.id,
      kind,
      actions,
      rejectDecision: available?.includes("decline") === false && available.includes("cancel") ? "cancel" : "decline",
    });
    state.session.status = "waiting_user";
    state.session.updatedAt = this.now().toISOString();
    const event: ApprovalEventInput = {
      type: "approval.requested",
      interactionId,
      title: kind === "command" ? "Approve command" : "Approve file changes",
      actions,
    };
    const reason = readString(params, "reason", false);
    const command = readString(params, "command", false);
    if (reason !== undefined) event.description = reason;
    if (command !== undefined) event.command = command;
    this.emit(state, event);
    this.emit(state, { type: "status", status: "waiting_user" });
  }

  private async ensureLoaded(state: SessionState): Promise<void> {
    await this.ensureStarted();
    if (state.loaded) return;
    state.loading ??= this.connection.request("thread/resume", { threadId: state.threadId, excludeTurns: true }).then(() => {
      state.loaded = true;
    });
    try { await state.loading; } finally { delete state.loading; }
  }

  private handleConnectionError(error: Error): void {
    this.started = false;
    for (const state of new Set(this.sessions.values())) {
      state.loaded = false;
      delete state.loading;
      const hadActiveTurn = state.activeTurnId !== undefined || state.turnStarting;
      state.turnStarting = false;
      delete state.activeTurnId;
      const hadApproval = state.pendingInteractions.size > 0;
      state.pendingInteractions.clear();
      this.emit(state, {
        type: "error",
        code: hadApproval ? "codex_interaction_expired" : "codex_connection_lost",
        message: error.message,
        recoverable: true,
      });
      if (hadApproval || hadActiveTurn) {
        state.session.status = "idle";
        this.emit(state, { type: "status", status: "idle" });
        this.emit(state, { type: "turn.completed", outcome: "failed" });
      }
    }
  }

  private captureNativeEvent(event: CodexNotification | CodexServerRequest): void {
    try { this.onNativeEvent(event); } catch { /* Debug capture must not interrupt the agent stream. */ }
  }

  private emit(state: SessionState, event: AgentEventInput): void {
    state.events.push({
      ...event,
      id: this.id(),
      sessionId: state.session.id,
      sequence: state.nextSequence,
      timestamp: this.now().toISOString(),
    } as AgentEvent);
    state.nextSequence += 1;
  }
}

type AgentEventInput = AgentEvent extends infer Event
  ? Event extends AgentEvent
    ? Omit<Event, "id" | "sessionId" | "sequence" | "timestamp">
    : never
  : never;
type CommandEventInput = Extract<AgentEventInput, { type: "command" }>;
type ToolFinishedEventInput = Extract<AgentEventInput, { type: "tool.finished" }>;
type ApprovalEventInput = Extract<AgentEventInput, { type: "approval.requested" }>;

class AsyncEventQueue implements AsyncIterable<AgentEvent> {
  private readonly buffered: AgentEvent[] = [];
  private readonly waiting: ((result: IteratorResult<AgentEvent>) => void)[] = [];
  private closed = false;

  push(event: AgentEvent): void {
    if (this.closed) return;
    const resolve = this.waiting.shift();
    if (resolve === undefined) this.buffered.push(event);
    else resolve({ done: false, value: event });
  }

  close(): void {
    this.closed = true;
    for (const resolve of this.waiting.splice(0)) resolve({ done: true, value: undefined });
  }

  [Symbol.asyncIterator](): AsyncIterator<AgentEvent> {
    return {
      next: async () => {
        const event = this.buffered.shift();
        if (event !== undefined) return { done: false, value: event };
        if (this.closed) return { done: true, value: undefined };
        return new Promise<IteratorResult<AgentEvent>>((resolve) => this.waiting.push(resolve));
      },
    };
  }
}

function approvalActions(value: unknown): ApprovalAction[] {
  if (!Array.isArray(value)) return ["approve_once", "approve_session", "reject"];
  const actions: ApprovalAction[] = [];
  if (value.includes("accept")) actions.push("approve_once");
  if (value.includes("acceptForSession")) actions.push("approve_session");
  if (value.includes("decline") || value.includes("cancel")) actions.push("reject");
  return actions.length === 0 ? ["reject"] : actions;
}

function decisionFor(action: ApprovalAction, rejectDecision: "decline" | "cancel"): "accept" | "acceptForSession" | "decline" | "cancel" {
  if (action === "approve_once") return "accept";
  if (action === "approve_session") return "acceptForSession";
  return rejectDecision;
}

function titleFor(prompt: string | undefined): string {
  const value = prompt?.trim();
  if (value === undefined || value.length === 0) return "New Codex session";
  return value.length <= 80 ? value : `${value.slice(0, 77)}...`;
}

function projectRelativePath(value: string, workingDirectory: string | undefined): string | undefined {
  if (workingDirectory === undefined) return isAbsolute(value) ? undefined : value.split(sep).join("/");
  const root = resolve(workingDirectory);
  const candidate = isAbsolute(value) ? resolve(value) : resolve(root, value);
  const path = relative(root, candidate);
  if (path.length === 0 || path === ".." || path.startsWith(`..${sep}`) || isAbsolute(path)) return undefined;
  return path.split(sep).join("/");
}

function readNestedString(value: unknown, objectKey: string, stringKey: string): string {
  return readString(asRecord(asRecord(value)[objectKey]), stringKey);
}

function readString(record: Record<string, unknown>, key: string, required?: true): string;
function readString(record: Record<string, unknown>, key: string, required: false): string | undefined;
function readString(record: Record<string, unknown>, key: string, required = true): string | undefined {
  const value = record[key];
  if (typeof value === "string") return value;
  if (!required) return undefined;
  throw new Error(`Codex payload is missing ${key}`);
}

function asRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Codex payload must be an object");
  return value as Record<string, unknown>;
}

function asOptionalRecord(value: unknown): Record<string, unknown> | undefined {
  if (value === undefined || value === null) return undefined;
  return asRecord(value);
}
