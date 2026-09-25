import type {
  AgentAdapter,
  AgentEvent,
  AgentInput,
  AgentSession,
  ApprovalAction,
  CreateSessionOptions,
  InteractionResponse,
  QuestionOption,
} from "@agentide/agent-core";
import {
  getSessionMessages,
  query,
  type CanUseTool,
  type PermissionResult,
  type PermissionUpdate,
  type SDKMessage,
} from "@anthropic-ai/claude-agent-sdk";

interface SessionState {
  session: AgentSession;
  nativeSessionId: string;
  workingDirectory: string | undefined;
  resumeOnNextTurn: boolean;
  nextSequence: number;
  events: AsyncEventQueue;
  activeTurn?: ActiveTurn;
  pendingInteractions: Map<string, PendingInteraction>;
  tools: Map<string, ToolState>;
}

interface ActiveTurn {
  abortController: AbortController;
  cancelled: boolean;
  completion: Promise<void>;
  started: Promise<void>;
  resolveStarted: () => void;
  rejectStarted: (error: unknown) => void;
}

interface ToolState {
  name: string;
  command?: string;
}

interface PendingApproval {
  kind: "approval";
  input: Record<string, unknown>;
  suggestions: PermissionUpdate[] | undefined;
  resolve: (result: PermissionResult) => void;
}

interface PendingQuestion {
  kind: "question";
  optionLabels: ReadonlyMap<string, string>;
  resolve: (answer: string) => void;
}

type PendingInteraction = PendingApproval | PendingQuestion;

export interface ClaudeQueryRequest {
  prompt: string;
  workingDirectory: string;
  nativeSessionId: string;
  resume: boolean;
  abortController: AbortController;
  canUseTool: CanUseTool;
}

export type ClaudeQueryFactory = (request: ClaudeQueryRequest) => AsyncIterable<SDKMessage>;

export interface ClaudeAdapterOptions {
  query?: ClaudeQueryFactory;
  sessionExists?: (nativeSessionId: string, workingDirectory: string) => Promise<boolean>;
  now?: () => Date;
  id?: () => string;
  onNativeEvent?: (event: SDKMessage) => void;
}

export class ClaudeAdapter implements AgentAdapter {
  readonly type = "claude" as const;
  private readonly runQuery: ClaudeQueryFactory;
  private readonly sessionExists: (nativeSessionId: string, workingDirectory: string) => Promise<boolean>;
  private readonly now: () => Date;
  private readonly id: () => string;
  private readonly onNativeEvent: (event: SDKMessage) => void;
  private readonly sessions = new Map<string, SessionState>();

  constructor(options: ClaudeAdapterOptions = {}) {
    this.runQuery = options.query ?? defaultQuery;
    this.sessionExists = options.sessionExists ?? defaultSessionExists;
    this.now = options.now ?? (() => new Date());
    this.id = options.id ?? (() => crypto.randomUUID());
    this.onNativeEvent = options.onNativeEvent ?? (() => undefined);
  }

  capabilities() {
    return { approvals: true, questions: true, resumeSession: true };
  }

  async createSession(options: CreateSessionOptions): Promise<AgentSession> {
    const timestamp = this.now().toISOString();
    const session: AgentSession = {
      id: options.sessionId,
      projectId: options.projectId,
      agentType: "claude",
      nativeSessionId: options.sessionId,
      title: titleFor(options.initialPrompt),
      status: "starting",
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    const state = this.register(session, options.sessionId, false, options.workingDirectory);
    this.emit(state, { type: "session.started", nativeSessionId: options.sessionId });
    return { ...state.session };
  }

  async resumeSession(nativeSessionId: string, workingDirectory?: string): Promise<AgentSession> {
    const existing = this.sessions.get(nativeSessionId);
    if (existing !== undefined) return { ...existing.session };
    const timestamp = this.now().toISOString();
    const session: AgentSession = {
      id: nativeSessionId,
      projectId: "",
      agentType: "claude",
      nativeSessionId,
      title: "Claude session",
      status: "idle",
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    const state = this.register(session, nativeSessionId, true, workingDirectory);
    this.emit(state, { type: "session.started", nativeSessionId });
    return { ...state.session };
  }

  async sendMessage(sessionId: string, input: AgentInput): Promise<void> {
    const state = this.requireSession(sessionId);
    if (state.activeTurn !== undefined) throw new Error("Claude session already has an active turn");
    if (state.workingDirectory === undefined) throw new Error("Claude session has no working directory");
    if (input.attachments !== undefined && input.attachments.length > 0) {
      throw new Error("Claude attachments are not supported yet");
    }
    const abortController = new AbortController();
    let resolveStarted!: () => void;
    let rejectStarted!: (error: unknown) => void;
    const started = new Promise<void>((resolve, reject) => {
      resolveStarted = resolve;
      rejectStarted = reject;
    });
    const turn: ActiveTurn = {
      abortController,
      cancelled: false,
      completion: Promise.resolve(),
      started,
      resolveStarted,
      rejectStarted,
    };
    state.activeTurn = turn;
    turn.completion = this.startTurn(state, turn, input);
    void turn.completion.catch(() => undefined);
    return started;
  }

  private async startTurn(state: SessionState, turn: ActiveTurn, input: AgentInput): Promise<void> {
    try {
      const resume = state.resumeOnNextTurn
        ? await this.sessionExists(state.nativeSessionId, state.workingDirectory ?? "")
        : false;
      throwIfAborted(turn.abortController.signal);
      state.session.status = "running";
      state.session.updatedAt = this.now().toISOString();
      this.emit(state, { type: "message", role: "user", content: input.content, format: "plain" });
      this.emit(state, { type: "status", status: "running" });
      const stream = this.runQuery({
        prompt: input.content,
        workingDirectory: state.workingDirectory ?? "",
        nativeSessionId: state.nativeSessionId,
        resume,
        abortController: turn.abortController,
        canUseTool: (toolName, toolInput, permissionOptions) =>
          this.requestPermission(state, toolName, toolInput, permissionOptions),
      });
      state.resumeOnNextTurn = true;
      turn.resolveStarted();
      await this.consume(state, turn, stream);
    } catch (error) {
      if (state.activeTurn === turn) {
        if (turn.cancelled || isAbortError(error)) this.finishTurn(state, turn, "cancelled");
        else this.failTurn(state, turn, "claude_turn_start_failed", error, true);
      }
      turn.rejectStarted(error);
    }
  }

  async cancel(sessionId: string): Promise<void> {
    const state = this.requireSession(sessionId);
    const turn = state.activeTurn;
    if (turn === undefined) return;
    turn.cancelled = true;
    this.resolvePendingAsDenied(state, "Claude turn was cancelled");
    turn.abortController.abort();
    await turn.completion;
  }

  async respondToInteraction(
    sessionId: string,
    interactionId: string,
    response: InteractionResponse,
  ): Promise<void> {
    const state = this.requireSession(sessionId);
    const pending = state.pendingInteractions.get(interactionId);
    if (pending === undefined) throw new Error("Interaction is not pending");
    if (pending.kind !== response.kind) throw new Error(`Claude interaction requires a ${pending.kind} response`);

    if (pending.kind === "approval" && response.kind === "approval") {
      const available = approvalActions(pending.suggestions);
      if (!available.includes(response.action)) throw new Error("Approval action is not available");
      if (response.action === "reject") {
        pending.resolve({ behavior: "deny", message: "User rejected this tool call" });
      } else {
        pending.resolve({
          behavior: "allow",
          updatedInput: pending.input,
          ...(response.action === "approve_session" && pending.suggestions !== undefined
            ? { updatedPermissions: pending.suggestions }
            : {}),
        });
      }
    } else if (pending.kind === "question" && response.kind === "question") {
      pending.resolve(answerFor(response, pending.optionLabels));
    }

    state.pendingInteractions.delete(interactionId);
    if (state.pendingInteractions.size === 0 && state.activeTurn !== undefined) {
      state.session.status = "running";
      state.session.updatedAt = this.now().toISOString();
      this.emit(state, { type: "status", status: "running" });
    }
  }

  events(sessionId: string): AsyncIterable<AgentEvent> {
    return this.requireSession(sessionId).events;
  }

  async close(): Promise<void> {
    const turns: Promise<void>[] = [];
    for (const state of this.sessions.values()) {
      if (state.activeTurn !== undefined) {
        state.activeTurn.cancelled = true;
        state.activeTurn.abortController.abort();
        turns.push(state.activeTurn.completion);
      }
      this.resolvePendingAsDenied(state, "Claude adapter closed");
    }
    await Promise.allSettled(turns);
    for (const state of this.sessions.values()) state.events.close();
    this.sessions.clear();
  }

  private register(
    session: AgentSession,
    nativeSessionId: string,
    resumeOnNextTurn: boolean,
    workingDirectory?: string,
  ): SessionState {
    const state: SessionState = {
      session,
      nativeSessionId,
      workingDirectory,
      resumeOnNextTurn,
      nextSequence: 0,
      events: new AsyncEventQueue(),
      pendingInteractions: new Map(),
      tools: new Map(),
    };
    this.sessions.set(session.id, state);
    return state;
  }

  private requireSession(sessionId: string): SessionState {
    const state = this.sessions.get(sessionId);
    if (state === undefined) throw new Error(`Claude session is not loaded: ${sessionId}`);
    return state;
  }

  private async consume(state: SessionState, turn: ActiveTurn, stream: AsyncIterable<SDKMessage>): Promise<void> {
    try {
      for await (const message of stream) {
        this.onNativeEvent(message);
        if (message.type === "stream_event") this.handleStreamEvent(state, message);
        else if (message.type === "assistant") this.handleAssistantMessage(state, message);
        else if (message.type === "user") this.handleUserMessage(state, message);
        else if (message.type === "result") {
          const failed = message.subtype !== "success" || message.is_error;
          if (failed && !turn.cancelled) {
            const errors = "errors" in message ? message.errors : [message.result];
            this.emit(state, {
              type: "error",
              code: "claude_turn_failed",
              message: errors.filter((value): value is string => typeof value === "string").join("\n") || "Claude turn failed",
              recoverable: true,
            });
          }
          this.finishTurn(state, turn, turn.cancelled ? "cancelled" : failed ? "failed" : "completed");
        }
      }
      if (state.activeTurn === turn) {
        this.finishTurn(state, turn, turn.cancelled ? "cancelled" : "failed", turn.cancelled ? undefined : {
          code: "claude_stream_ended",
          message: "Claude event stream ended before reporting a result",
        });
      }
    } catch (error) {
      if (state.activeTurn !== turn) return;
      if (turn.cancelled || isAbortError(error)) this.finishTurn(state, turn, "cancelled");
      else this.failTurn(state, turn, "claude_connection_lost", error, true);
    }
  }

  private handleStreamEvent(state: SessionState, message: Extract<SDKMessage, { type: "stream_event" }>): void {
    if (message.parent_tool_use_id !== null) return;
    const event = asRecord(message.event);
    if (event.type !== "content_block_delta") return;
    const delta = asOptionalRecord(event.delta);
    if (delta?.type === "text_delta" && typeof delta.text === "string") {
      this.emit(state, { type: "text.delta", content: delta.text });
    }
  }

  private handleAssistantMessage(state: SessionState, message: Extract<SDKMessage, { type: "assistant" }>): void {
    if (message.parent_tool_use_id !== null) return;
    for (const value of message.message.content) {
      const block = asRecord(value);
      if (block.type === "text" && typeof block.text === "string") {
        this.emit(state, { type: "message", role: "agent", content: block.text, format: "markdown" });
      } else if (block.type === "tool_use" && typeof block.id === "string" && typeof block.name === "string") {
        const input = asOptionalRecord(block.input) ?? {};
        const command = block.name === "Bash" && typeof input.command === "string" ? input.command : undefined;
        state.tools.set(block.id, { name: block.name, ...(command === undefined ? {} : { command }) });
        this.emit(state, { type: "tool.started", toolName: block.name, title: block.name, input });
        if (command !== undefined) this.emit(state, { type: "command", command, status: "started" });
      }
    }
  }

  private handleUserMessage(state: SessionState, message: Extract<SDKMessage, { type: "user" }>): void {
    if (message.parent_tool_use_id !== null || !Array.isArray(message.message.content)) return;
    for (const value of message.message.content) {
      const block = asRecord(value);
      if (block.type !== "tool_result" || typeof block.tool_use_id !== "string") continue;
      const tool = state.tools.get(block.tool_use_id);
      if (tool === undefined) continue;
      const failed = block.is_error === true;
      const output = message.tool_use_result !== undefined ? message.tool_use_result : block.content;
      this.emit(state, {
        type: "tool.finished",
        toolName: tool.name,
        ...(failed ? { error: stringValue(output) } : { output }),
      });
      if (tool.command !== undefined) {
        this.emit(state, { type: "command", command: tool.command, status: failed ? "failed" : "completed" });
      }
      state.tools.delete(block.tool_use_id);
    }
  }

  private async requestPermission(
    state: SessionState,
    toolName: string,
    input: Record<string, unknown>,
    options: Parameters<CanUseTool>[2],
  ): Promise<PermissionResult> {
    throwIfAborted(options.signal);
    if (toolName === "AskUserQuestion") return this.requestQuestions(state, input, options.toolUseID, options.signal);

    const interactionId = options.toolUseID;
    if (state.pendingInteractions.has(interactionId)) throw new Error("Claude interaction id is already pending");
    const sessionSuggestions = options.suppressAlwaysAllowRule === true
      ? undefined
      : options.suggestions?.map((suggestion) => ({ ...suggestion, destination: "session" as const }));
    const result = new Promise<PermissionResult>((resolve, reject) => {
      const abort = (): void => reject(options.signal.reason ?? new Error("Claude permission request was aborted"));
      options.signal.addEventListener("abort", abort, { once: true });
      state.pendingInteractions.set(interactionId, {
        kind: "approval",
        input,
        suggestions: sessionSuggestions,
        resolve: (value) => {
          options.signal.removeEventListener("abort", abort);
          resolve(value);
        },
      });
    });
    this.emit(state, {
      type: "approval.requested",
      interactionId,
      title: options.title ?? options.displayName ?? `Allow ${toolName}`,
      ...(options.description === undefined ? {} : { description: options.description }),
      ...(toolName === "Bash" && typeof input.command === "string" ? { command: input.command } : {}),
      actions: approvalActions(sessionSuggestions),
    });
    this.markWaiting(state);
    return result;
  }

  private async requestQuestions(
    state: SessionState,
    input: Record<string, unknown>,
    toolUseId: string,
    signal: AbortSignal,
  ): Promise<PermissionResult> {
    throwIfAborted(signal);
    const questions = parseQuestions(input);
    if (questions.length === 0) return { behavior: "deny", message: "Claude asked an invalid question" };
    const answers: Record<string, string> = {};
    const pendingAnswers = questions.map(async (question, index) => {
      const interactionId = questions.length === 1 ? toolUseId : `${toolUseId}:${index}`;
      const optionLabels = new Map(question.options.map((option) => [option.id, option.label]));
      answers[question.question] = await new Promise<string>((resolve, reject) => {
        const abort = (): void => reject(signal.reason ?? new Error("Claude question was aborted"));
        signal.addEventListener("abort", abort, { once: true });
        state.pendingInteractions.set(interactionId, {
          kind: "question",
          optionLabels,
          resolve: (value) => {
            signal.removeEventListener("abort", abort);
            resolve(value);
          },
        });
        this.emit(state, {
          type: "question.requested",
          interactionId,
          question: question.question,
          ...(question.options.length === 0 ? {} : { options: question.options }),
          allowFreeText: true,
        });
      });
    });
    this.markWaiting(state);
    await Promise.all(pendingAnswers);
    return { behavior: "allow", updatedInput: { ...input, answers } };
  }

  private markWaiting(state: SessionState): void {
    state.session.status = "waiting_user";
    state.session.updatedAt = this.now().toISOString();
    this.emit(state, { type: "status", status: "waiting_user" });
  }

  private resolvePendingAsDenied(state: SessionState, message: string): void {
    for (const pending of state.pendingInteractions.values()) {
      if (pending.kind === "approval") pending.resolve({ behavior: "deny", message });
      else pending.resolve(message);
    }
    state.pendingInteractions.clear();
  }

  private finishTurn(
    state: SessionState,
    turn: ActiveTurn,
    outcome: "completed" | "failed" | "cancelled",
    error?: { code: string; message: string },
  ): void {
    if (state.activeTurn !== turn) return;
    this.resolvePendingAsDenied(state, `Claude turn ${outcome}`);
    for (const tool of state.tools.values()) {
      this.emit(state, {
        type: "tool.finished",
        toolName: tool.name,
        error: `Claude turn ${outcome} before the tool reported a result`,
      });
      if (tool.command !== undefined) {
        this.emit(state, { type: "command", command: tool.command, status: "failed" });
      }
    }
    state.tools.clear();
    delete state.activeTurn;
    state.session.status = "idle";
    state.session.updatedAt = this.now().toISOString();
    if (error !== undefined) this.emit(state, { type: "error", ...error, recoverable: true });
    this.emit(state, { type: "status", status: "idle" });
    this.emit(state, { type: "turn.completed", outcome });
  }

  private failTurn(state: SessionState, turn: ActiveTurn, code: string, error: unknown, recoverable: boolean): void {
    this.finishTurn(state, turn, "failed", {
      code,
      message: error instanceof Error ? error.message : "Claude turn failed",
    });
    if (!recoverable) state.events.close();
  }

  private emit(state: SessionState, event: EventInput): void {
    state.events.push({
      ...event,
      id: this.id(),
      sessionId: state.session.id,
      sequence: state.nextSequence++,
      timestamp: this.now().toISOString(),
    } as AgentEvent);
  }
}

type EventInput = AgentEvent extends infer Event
  ? Event extends AgentEvent
    ? Omit<Event, "id" | "sessionId" | "sequence" | "timestamp">
    : never
  : never;

function defaultQuery(request: ClaudeQueryRequest): AsyncIterable<SDKMessage> {
  return query({
    prompt: request.prompt,
    options: {
      abortController: request.abortController,
      canUseTool: request.canUseTool,
      cwd: request.workingDirectory,
      includePartialMessages: true,
      permissionMode: "default",
      ...(request.resume
        ? { resume: request.nativeSessionId }
        : { sessionId: request.nativeSessionId }),
    },
  });
}

async function defaultSessionExists(nativeSessionId: string, workingDirectory: string): Promise<boolean> {
  return (await getSessionMessages(nativeSessionId, { dir: workingDirectory, limit: 1 })).length > 0;
}

function approvalActions(suggestions: PermissionUpdate[] | undefined): ApprovalAction[] {
  return suggestions === undefined || suggestions.length === 0
    ? ["approve_once", "reject"]
    : ["approve_once", "approve_session", "reject"];
}

function answerFor(
  response: Extract<InteractionResponse, { kind: "question" }>,
  optionLabels: ReadonlyMap<string, string>,
): string {
  const labels = (response.optionIds ?? []).map((id) => {
    const label = optionLabels.get(id);
    if (label === undefined) throw new Error(`Question option is not available: ${id}`);
    return label;
  });
  const freeText = response.freeText?.trim();
  if (freeText !== undefined && freeText.length > 0) labels.push(freeText);
  if (labels.length === 0) throw new Error("Question response must select an option or include free text");
  return labels.join(", ");
}

function parseQuestions(input: Record<string, unknown>): Array<{ question: string; options: QuestionOption[] }> {
  if (!Array.isArray(input.questions)) return [];
  return input.questions.flatMap((value, questionIndex) => {
    const question = asOptionalRecord(value);
    if (question === undefined || typeof question.question !== "string") return [];
    const rawOptions = Array.isArray(question.options) ? question.options : [];
    const options = rawOptions.flatMap((optionValue, optionIndex) => {
      const option = asOptionalRecord(optionValue);
      if (option === undefined || typeof option.label !== "string") return [];
      return [{
        id: `${questionIndex}:${optionIndex}`,
        label: option.label,
        ...(typeof option.description === "string" ? { description: option.description } : {}),
      }];
    });
    return [{ question: question.question, options }];
  });
}

function titleFor(prompt: string | undefined): string {
  const value = prompt?.trim() ?? "";
  if (value.length === 0) return "New Claude session";
  return value.length <= 80 ? value : `${value.slice(0, 77)}...`;
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && (error.name === "AbortError" || error.message.toLowerCase().includes("aborted"));
}

function throwIfAborted(signal: AbortSignal): void {
  if (!signal.aborted) return;
  throw signal.reason instanceof Error ? signal.reason : new DOMException("Aborted", "AbortError");
}

function stringValue(value: unknown): string {
  if (typeof value === "string") return value;
  try { return JSON.stringify(value); } catch { return "Claude tool failed"; }
}

function asRecord(value: unknown): Record<string, unknown> {
  return asOptionalRecord(value) ?? {};
}

function asOptionalRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

class AsyncEventQueue implements AsyncIterable<AgentEvent> {
  private readonly buffered: AgentEvent[] = [];
  private readonly waiting: Array<(result: IteratorResult<AgentEvent>) => void> = [];
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
