import type { AgentType, Session, SessionStatus } from "@agentide/shared-types";
import { isProtocolTimestamp } from "@agentide/protocol";
import { z } from "zod";

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

export interface TestReportFailure {
  name: string;
  message?: string;
}

export interface TestReportPayload {
  total: number;
  passed: number;
  failed: number;
  skipped: number;
  failures: TestReportFailure[];
}

export interface PlanReportPayload {
  steps: { title: string; status: "pending" | "in_progress" | "completed" | "blocked" }[];
}

export interface TodoReportPayload {
  items: { title: string; status: "not_started" | "in_progress" | "completed" | "blocked" }[];
}

export interface DiagnosticsReportPayload {
  items: {
    severity: "error" | "warning" | "info";
    message: string;
    relativePath?: string;
    line?: number;
    column?: number;
  }[];
}

const projectRelativePathSchema = z.string().min(1).regex(
  /^(?!\/)(?![A-Za-z]:\/)(?!.*\\)(?!.*(?:^|\/)\.{1,2}(?:\/|$))(?!.*\/\/)(?!.+\/$).+$/,
);

const reportInputFields = {
  reportVersion: z.literal(1),
  reportId: z.string().min(1),
  title: z.string().min(1),
  summary: z.string(),
};

const testReportPayloadSchema = z.object({
  total: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  passed: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  failed: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  skipped: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  failures: z.array(z.object({ name: z.string(), message: z.string().optional() }).strict()),
}).strict().refine(
  ({ total, passed, failed, skipped }) => total === passed + failed + skipped,
  "Test report totals must equal passed + failed + skipped",
);

const planReportPayloadSchema = z.object({
  steps: z.array(z.object({
    title: z.string(),
    status: z.enum(["pending", "in_progress", "completed", "blocked"]),
  }).strict()),
}).strict();

const todoReportPayloadSchema = z.object({
  items: z.array(z.object({
    title: z.string(),
    status: z.enum(["not_started", "in_progress", "completed", "blocked"]),
  }).strict()),
}).strict();

const diagnosticsReportPayloadSchema = z.object({
  items: z.array(z.object({
    severity: z.enum(["error", "warning", "info"]),
    message: z.string(),
    relativePath: projectRelativePathSchema.optional(),
    line: z.number().int().positive().max(Number.MAX_SAFE_INTEGER).optional(),
    column: z.number().int().positive().max(Number.MAX_SAFE_INTEGER).optional(),
  }).strict().refine(({ column, line }) => column === undefined || line !== undefined, "Diagnostic columns require a line")),
}).strict();

/** Shared v1 model-tool contract; adapter schemas are derived from this definition. */
export const reportInputSchema = z.discriminatedUnion("kind", [
  z.object({ ...reportInputFields, kind: z.literal("test_report"), payload: testReportPayloadSchema }).strict(),
  z.object({ ...reportInputFields, kind: z.literal("plan"), payload: planReportPayloadSchema }).strict(),
  z.object({ ...reportInputFields, kind: z.literal("todo"), payload: todoReportPayloadSchema }).strict(),
  z.object({ ...reportInputFields, kind: z.literal("diagnostics"), payload: diagnosticsReportPayloadSchema }).strict(),
]);

export type ReportInputV1 = z.infer<typeof reportInputSchema>;

export const reportInputJsonSchema = z.toJSONSchema(reportInputSchema);

export function parseReportInput(value: unknown): ReportInputV1 | undefined {
  const result = reportInputSchema.safeParse(value);
  return result.success ? result.data : undefined;
}

export type ReportPayload = ReportInputV1["payload"] | Record<string, unknown>;

export type ReportEventInput = { type: "report" } & ReportInputV1;

export type KnownReportEvent = BaseEvent & ReportEventInput;

export interface UnknownReportEvent extends BaseEvent {
  type: "report";
  reportVersion: number;
  reportId: string;
  kind: string;
  title: string;
  summary: string;
  payload: ReportPayload;
}

export type ReportEvent = KnownReportEvent | UnknownReportEvent;

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
  | SessionCompletedEvent
  | ReportEvent;

export type PendingInteraction = ApprovalRequestedEvent | QuestionRequestedEvent;

export interface SessionSnapshot {
  session: Session;
  recentEvents: AgentEvent[];
  pendingInteractions: PendingInteraction[];
  latestSequence: number;
  currentStatus: SessionStatus;
}

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
    case "report":
      return isReportEvent(value);
    default:
      return false;
  }
}

export function isReportEvent(value: unknown): value is ReportEvent {
  if (
    !isRecord(value) ||
    !isBaseEvent(value) ||
    value.type !== "report" ||
    !hasOnlyKeys(value, [
      "id",
      "sessionId",
      "sequence",
      "timestamp",
      "type",
      "reportVersion",
      "reportId",
      "kind",
      "title",
      "summary",
      "payload",
    ]) ||
    !isPositiveInteger(value.reportVersion) ||
    !isNonEmptyString(value.reportId) ||
    typeof value.kind !== "string" ||
    !isNonEmptyString(value.title) ||
    typeof value.summary !== "string" ||
    !isRecord(value.payload)
  ) {
    return false;
  }

  if (value.reportVersion !== 1) {
    return true;
  }

  if (!["test_report", "plan", "todo", "diagnostics"].includes(value.kind)) {
    return true;
  }

  return parseReportInput({
    reportVersion: value.reportVersion,
    reportId: value.reportId,
    kind: value.kind,
    title: value.title,
    summary: value.summary,
    payload: value.payload,
  }) !== undefined;
}

export function isKnownReportEvent(value: unknown): value is KnownReportEvent {
  return (
    isReportEvent(value) &&
    value.reportVersion === 1 &&
    ["test_report", "plan", "todo", "diagnostics"].includes(value.kind)
  );
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function isPositiveInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && typeof value === "number" && value > 0;
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
