import type { AgentType, Session } from "@agentide/shared-types";
import { isProtocolTimestamp } from "@agentide/protocol";

export interface BaseEvent {
  id: string;
  sessionId: string;
  sequence: number;
  timestamp: string;
  type: string;
}

export interface SessionStartedEvent extends BaseEvent {
  type: "session.started";
  nativeSessionId?: string;
}

export interface TextDeltaEvent extends BaseEvent {
  type: "text.delta";
  content: string;
}

export interface MessageEvent extends BaseEvent {
  type: "message";
  role: "agent" | "user" | "system";
  content: string;
  format: "plain" | "markdown";
}

export interface ToolStartedEvent extends BaseEvent {
  type: "tool.started";
  toolName: string;
  title?: string;
  input?: unknown;
}

export interface ToolFinishedEvent extends BaseEvent {
  type: "tool.finished";
  toolName: string;
  output?: unknown;
  error?: string;
}

export interface CommandEvent extends BaseEvent {
  type: "command";
  command: string;
  status: "started" | "completed" | "failed";
  exitCode?: number;
}

export interface FileChangedEvent extends BaseEvent {
  type: "file.changed";
  relativePath: string;
  change: "created" | "modified" | "deleted";
}

export type ApprovalAction = "approve_once" | "approve_session" | "reject";

export interface ApprovalRequestedEvent extends BaseEvent {
  type: "approval.requested";
  interactionId: string;
  title: string;
  description?: string;
  command?: string;
  actions: ApprovalAction[];
}

export interface QuestionOption {
  id: string;
  label: string;
  description?: string;
}

export interface QuestionRequestedEvent extends BaseEvent {
  type: "question.requested";
  interactionId: string;
  question: string;
  options?: QuestionOption[];
  allowFreeText: boolean;
}

export interface StatusEvent extends BaseEvent {
  type: "status";
  status: "running" | "idle" | "waiting_user";
  message?: string;
}

export interface ErrorEvent extends BaseEvent {
  type: "error";
  code: string;
  message: string;
  recoverable: boolean;
}

export interface SessionCompletedEvent extends BaseEvent {
  type: "session.completed";
  outcome: "completed" | "failed" | "cancelled";
}

export interface TurnCompletedEvent extends BaseEvent {
  type: "turn.completed";
  outcome: "completed" | "failed" | "cancelled";
}

export type AgentEvent =
  | SessionStartedEvent
  | TextDeltaEvent
  | MessageEvent
  | ToolStartedEvent
  | ToolFinishedEvent
  | CommandEvent
  | FileChangedEvent
  | ApprovalRequestedEvent
  | QuestionRequestedEvent
  | StatusEvent
  | ErrorEvent
  | TurnCompletedEvent
  | SessionCompletedEvent;

export interface AgentCapabilities {
  approvals: boolean;
  questions: boolean;
  resumeSession: boolean;
}

export interface CreateSessionOptions {
  sessionId: string;
  projectId: string;
  workingDirectory: string;
  initialPrompt?: string;
}

export type AgentSession = Session;

export interface AgentInput {
  content: string;
  attachments?: { name: string; mediaType: string; data: string }[];
}

export type InteractionResponse =
  | { kind: "approval"; action: ApprovalAction }
  | { kind: "question"; optionIds?: string[]; freeText?: string };

export interface AgentAdapter {
  readonly type: AgentType;

  capabilities(): AgentCapabilities;
  createSession(options: CreateSessionOptions): Promise<AgentSession>;
  resumeSession(nativeSessionId: string, workingDirectory?: string): Promise<AgentSession>;
  sendMessage(sessionId: string, input: AgentInput): Promise<void>;
  cancel(sessionId: string): Promise<void>;
  respondToInteraction(
    sessionId: string,
    interactionId: string,
    response: InteractionResponse,
  ): Promise<void>;
  events(sessionId: string): AsyncIterable<AgentEvent>;
}

export function isAgentEvent(value: unknown): value is AgentEvent {
  if (!isRecord(value) || !isBaseEvent(value)) {
    return false;
  }

  switch (value.type) {
    case "session.started":
      return optionalString(value.nativeSessionId);
    case "text.delta":
      return typeof value.content === "string";
    case "message":
      return (
        typeof value.role === "string" &&
        ["agent", "user", "system"].includes(value.role) &&
        typeof value.content === "string" &&
        typeof value.format === "string" &&
        ["plain", "markdown"].includes(value.format)
      );
    case "tool.started":
      return typeof value.toolName === "string" && optionalString(value.title);
    case "tool.finished":
      return typeof value.toolName === "string" && optionalString(value.error);
    case "command":
      return (
        typeof value.command === "string" &&
        typeof value.status === "string" &&
        ["started", "completed", "failed"].includes(value.status) &&
        (value.exitCode === undefined || Number.isInteger(value.exitCode))
      );
    case "file.changed":
      return (
        typeof value.relativePath === "string" &&
        typeof value.change === "string" &&
        ["created", "modified", "deleted"].includes(value.change)
      );
    case "approval.requested":
      return (
        typeof value.interactionId === "string" &&
        typeof value.title === "string" &&
        optionalString(value.description) &&
        optionalString(value.command) &&
        Array.isArray(value.actions) &&
        value.actions.length > 0 &&
        value.actions.every(
          (action) =>
            typeof action === "string" &&
            ["approve_once", "approve_session", "reject"].includes(action),
        )
      );
    case "question.requested":
      return (
        typeof value.interactionId === "string" &&
        typeof value.question === "string" &&
        typeof value.allowFreeText === "boolean" &&
        (value.options === undefined || isQuestionOptions(value.options))
      );
    case "status":
      return (
        typeof value.status === "string" &&
        ["running", "idle", "waiting_user"].includes(value.status) &&
        optionalString(value.message)
      );
    case "error":
      return (
        typeof value.code === "string" &&
        typeof value.message === "string" &&
        typeof value.recoverable === "boolean"
      );
    case "session.completed":
    case "turn.completed":
      return (
        typeof value.outcome === "string" &&
        ["completed", "failed", "cancelled"].includes(value.outcome)
      );
    default:
      return false;
  }
}

function isBaseEvent(value: Record<string, unknown>): boolean {
  return (
    typeof value.id === "string" &&
    value.id.length > 0 &&
    typeof value.sessionId === "string" &&
    value.sessionId.length > 0 &&
    Number.isInteger(value.sequence) &&
    Number(value.sequence) >= 0 &&
    isProtocolTimestamp(value.timestamp) &&
    typeof value.type === "string"
  );
}

function isQuestionOptions(value: unknown): boolean {
  return (
    Array.isArray(value) &&
    value.every(
      (option) =>
        isRecord(option) &&
        hasOnlyKeys(option, ["id", "label", "description"]) &&
        typeof option.id === "string" &&
        typeof option.label === "string" &&
        optionalString(option.description),
    )
  );
}

function optionalString(value: unknown): boolean {
  return value === undefined || typeof value === "string";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: readonly string[]): boolean {
  return Object.keys(value).every((key) => allowed.includes(key));
}
