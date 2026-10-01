import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { AgentEvent } from "@agentide/agent-core";
import type { Session } from "@agentide/shared-types";
import { NotificationOutbox, type NotificationOutboxPage } from "./notification-outbox.js";

interface StoredSessions {
  sessions: Session[];
  events: Record<string, AgentEvent[]>;
  resolvedInteractions: Record<string, ResolvedInteraction[]>;
}

interface ResolvedInteraction {
  interactionId: string;
  sequence: number;
}

const notificationReconcileBatchSize = 256;

export interface StoredSessionSnapshot {
  session: Session;
  events: AgentEvent[];
  resolvedInteractionSequences: ReadonlyMap<string, ReadonlySet<number>>;
}

export class SessionStore {
  private data: StoredSessions | undefined;
  private loading: Promise<void> | undefined;
  private mutations: Promise<void> = Promise.resolve();
  private notificationWrites: Promise<void> = Promise.resolve();
  private notificationError: unknown;
  private notificationNeedsRecovery = true;
  private notificationRecoveryQueued = false;
  private notificationAppendQueued = false;
  private readonly pendingNotificationEvents = new Map<string, {
    session: Session;
    fromSequence: number;
    throughSequence: number;
  }>();
  private readonly eventWaiters = new Map<string, Set<(event: AgentEvent) => void>>();

  constructor(
    private readonly filePath: string,
    private readonly notificationOutbox = new NotificationOutbox(`${filePath}.notifications.json`),
  ) {}

  async notificationPage(afterCursor?: number, limit?: number): Promise<NotificationOutboxPage> {
    await this.flushNotifications();
    return this.notificationOutbox.page(afterCursor, limit);
  }

  acknowledgeNotifications(cursor: number): Promise<void> {
    return this.notificationOutbox.acknowledge(cursor);
  }

  async flushNotifications(): Promise<void> {
    await this.load();
    this.queueNotificationRecovery();
    await this.notificationWrites;
    if (this.notificationError !== undefined) throw this.notificationError;
  }

  async list(projectId?: string): Promise<Session[]> {
    await this.mutations;
    await this.load();
    const sessions = this.data?.sessions ?? [];
    return sessions.filter((session) => projectId === undefined || session.projectId === projectId).map((session) => ({ ...session }));
  }

  async get(id: string): Promise<Session | undefined> {
    return (await this.list()).find((session) => session.id === id);
  }

  async events(sessionId: string, afterSequence = -1): Promise<AgentEvent[]> {
    await this.mutations;
    await this.load();
    return (this.data?.events[sessionId] ?? []).slice(Math.max(0, afterSequence + 1)).map((event) => ({ ...event }));
  }

  async snapshot(sessionId: string): Promise<StoredSessionSnapshot | undefined> {
    await this.mutations;
    await this.load();
    const session = this.data?.sessions.find((value) => value.id === sessionId);
    if (session === undefined) return undefined;
    return {
      session: { ...session },
      events: (this.data?.events[sessionId] ?? []).map((event) => ({ ...event })),
      resolvedInteractionSequences: resolvedInteractionSequences(this.data?.resolvedInteractions[sessionId] ?? []),
    };
  }

  async create(session: Session): Promise<void> {
    await this.mutate(async (data) => {
      if (data.sessions.some((value) => value.id === session.id)) throw new Error("Session already exists");
      data.sessions.push({ ...session });
      data.events[session.id] = [];
      data.resolvedInteractions[session.id] = [];
    });
  }

  async resolveInteraction(sessionId: string, interactionId: string): Promise<void> {
    await this.resolveInteractions(sessionId, [interactionId]);
  }

  async resolveInteractions(sessionId: string, interactionIds: Iterable<string>): Promise<void> {
    await this.mutate(async (data) => {
      if (!data.sessions.some((session) => session.id === sessionId)) throw new Error("Session not found");
      const resolved = resolvedInteractionSequences(data.resolvedInteractions[sessionId] ?? []);
      const events = data.events[sessionId] ?? [];
      for (const interactionId of interactionIds) {
        const request = latestInteractionRequest(events, interactionId);
        if (request !== undefined) {
          const sequences = resolved.get(interactionId) ?? new Set<number>();
          sequences.add(request.sequence);
          resolved.set(interactionId, sequences);
        }
      }
      data.resolvedInteractions[sessionId] = [...resolved].flatMap(([interactionId, sequences]) =>
        [...sequences].map((sequence) => ({ interactionId, sequence })),
      );
    });
  }

  async record(sessionId: string, event: AgentEvent): Promise<AgentEvent> {
    await this.load();
    let stored: AgentEvent | undefined;
    const result = this.mutations.then(async () => {
      const data = this.data;
      if (data === undefined) throw new Error("Session store failed to load");
      const sessionIndex = data.sessions.findIndex((value) => value.id === sessionId);
      const session = data.sessions[sessionIndex];
      if (session === undefined) throw new Error("Session not found");
      const events = data.events[sessionId] ?? [];
      stored = { ...event, sessionId, sequence: (events.at(-1)?.sequence ?? -1) + 1 };
      const nextSession = { ...session, updatedAt: stored.timestamp };
      const resolvedInteractions = { ...data.resolvedInteractions };
      if (stored.type === "status") nextSession.status = stored.status;
      else if (stored.type === "approval.requested" || stored.type === "question.requested") nextSession.status = "waiting_user";
      else if (stored.type === "turn.completed") nextSession.status = "idle";
      else if (stored.type === "session.completed") nextSession.status = stored.outcome;
      const sessions = [...data.sessions];
      sessions[sessionIndex] = nextSession;
      try {
        await this.appendEvent(sessionId, stored);
        if (changesSessionStatus(stored)) await this.save({ sessions, resolvedInteractions });
      } catch (error) {
        this.data = undefined;
        this.loading = undefined;
        throw error;
      }
      events.push(stored);
      data.events[sessionId] = events;
      data.sessions = sessions;
      data.resolvedInteractions = resolvedInteractions;
      for (const notify of this.eventWaiters.get(sessionId) ?? []) notify(stored);
      this.queueNotificationAppend(nextSession, stored);
    });
    this.mutations = result.then(() => undefined, () => undefined);
    await result;
    if (stored === undefined) throw new Error("Event was not stored");
    return stored;
  }

  async waitForEvent(
    sessionId: string,
    afterSequence: number,
    predicate: (event: AgentEvent) => boolean,
    timeoutMilliseconds = 10_000,
  ): Promise<AgentEvent> {
    const existing = (await this.events(sessionId, afterSequence)).find(predicate);
    if (existing !== undefined) return existing;
    return new Promise<AgentEvent>((resolve, reject) => {
      const waiters = this.eventWaiters.get(sessionId) ?? new Set<(event: AgentEvent) => void>();
      const finish = (event: AgentEvent): void => {
        if (event.sequence <= afterSequence || !predicate(event)) return;
        clearTimeout(timeout);
        waiters.delete(finish);
        if (waiters.size === 0) this.eventWaiters.delete(sessionId);
        resolve({ ...event });
      };
      const timeout = setTimeout(() => {
        waiters.delete(finish);
        if (waiters.size === 0) this.eventWaiters.delete(sessionId);
        reject(new Error("Timed out waiting for the agent turn to be persisted"));
      }, timeoutMilliseconds);
      waiters.add(finish);
      this.eventWaiters.set(sessionId, waiters);
    });
  }

  private async load(): Promise<void> {
    if (this.data !== undefined) return;
    this.loading ??= this.loadOnce();
    await this.loading;
  }

  private async loadOnce(): Promise<void> {
    try {
      const value: unknown = JSON.parse(await readFile(this.filePath, "utf8"));
      if (!isRecord(value) || !Array.isArray(value.sessions) || (value.events !== undefined && !isRecord(value.events)) || (value.resolvedInteractions !== undefined && !isRecord(value.resolvedInteractions))) {
        throw new Error("Session store has an invalid shape");
      }
      const sessions = value.sessions as Session[];
      const legacy = isRecord(value.events) ? value.events as Record<string, AgentEvent[]> : {};
      const resolvedInteractions = isRecord(value.resolvedInteractions)
        ? Object.fromEntries(Object.entries(value.resolvedInteractions).map(([sessionId, interactions]) => [
          sessionId,
          parseResolvedInteractions(interactions),
        ])) as Record<string, ResolvedInteraction[]>
        : {};
      const eventEntries = await Promise.all(sessions.map(async (session) => {
        let persisted: AgentEvent[] = [];
        try {
          const path = this.eventPath(session.id);
          const content = await readFile(path, "utf8");
          persisted = parseEventLog(content);
          // parseEventLog tolerates a partial final record, but appending before repair would join the next event onto that corrupt tail.
          if (content.length > 0 && !content.endsWith("\n")) await rewriteEventLog(path, persisted);
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        }
        return [session.id, [...(legacy[session.id] ?? []), ...persisted]] as [string, AgentEvent[]];
      }));
      const events = Object.fromEntries(eventEntries);
      this.data = {
        sessions: sessions.map((session) => deriveSession(session, events[session.id] ?? [])),
        events,
        resolvedInteractions,
      };
      this.queueNotificationRecovery();
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      this.data = { sessions: [], events: {}, resolvedInteractions: {} };
      this.queueNotificationRecovery();
    }
  }

  private queueNotificationRecovery(): void {
    if (!this.notificationNeedsRecovery || this.notificationRecoveryQueued) return;
    this.notificationRecoveryQueued = true;
    this.queueNotificationWrite(async () => {
      try {
        const data = this.data;
        if (data === undefined) return;
        for (const session of data.sessions) {
          await this.reconcileNotificationRange(
            session,
            data.events[session.id] ?? [],
            0,
            data.events[session.id]?.length ?? 0,
          );
        }
        this.notificationNeedsRecovery = false;
        this.notificationError = undefined;
      } finally {
        this.notificationRecoveryQueued = false;
      }
    });
  }

  private queueNotificationAppend(session: Session, event: AgentEvent): void {
    const pending = this.pendingNotificationEvents.get(session.id) ?? {
      session: { ...session },
      fromSequence: event.sequence,
      throughSequence: event.sequence,
    };
    pending.session = { ...session };
    pending.fromSequence = Math.min(pending.fromSequence, event.sequence);
    pending.throughSequence = Math.max(pending.throughSequence, event.sequence);
    this.pendingNotificationEvents.set(session.id, pending);
    if (this.notificationAppendQueued) return;
    this.queueNotificationAppendWork();
  }

  private queueNotificationAppendWork(): void {
    if (this.notificationAppendQueued) return;
    this.notificationAppendQueued = true;
    this.queueNotificationWrite(async () => {
      try {
        await this.drainPendingNotificationEvents();
      } finally {
        this.notificationAppendQueued = false;
        if (this.pendingNotificationEvents.size > 0) this.queueNotificationAppendWork();
      }
    });
  }

  private async drainPendingNotificationEvents(): Promise<void> {
    while (this.pendingNotificationEvents.size > 0) {
      const batch = new Map(this.pendingNotificationEvents);
      this.pendingNotificationEvents.clear();
      if (this.notificationNeedsRecovery) continue;
      for (const [sessionId, values] of batch) {
        const events = this.data?.events[sessionId] ?? [];
        await this.reconcileNotificationRange(
          values.session,
          events,
          values.fromSequence,
          values.throughSequence + 1,
        );
      }
    }
  }

  private async reconcileNotificationRange(
    session: Session,
    events: readonly AgentEvent[],
    fromIndex: number,
    throughIndex: number,
  ): Promise<void> {
    for (let index = fromIndex; index < throughIndex; index += notificationReconcileBatchSize) {
      const batch = events.slice(index, Math.min(index + notificationReconcileBatchSize, throughIndex));
      await this.notificationOutbox.reconcile([session], { [session.id]: batch });
    }
  }

  private queueNotificationWrite(work: () => Promise<void>): void {
    const attempt = this.notificationWrites.then(work);
    this.notificationWrites = attempt.then(
      () => undefined,
      (error) => {
        this.notificationError = error;
        this.notificationNeedsRecovery = true;
      },
    );
  }

  private async mutate(operation: (data: StoredSessions) => Promise<void>): Promise<void> {
    await this.load();
    const result = this.mutations.then(async () => {
      const current = this.data;
      if (current === undefined) throw new Error("Session store failed to load");
      const next = structuredClone(current);
      await operation(next);
      await this.save(next);
      this.data = next;
    });
    this.mutations = result.then(() => undefined, () => undefined);
    return result;
  }

  private async appendEvent(sessionId: string, event: AgentEvent): Promise<void> {
    const path = this.eventPath(sessionId);
    await mkdir(dirname(path), { recursive: true });
    await appendFile(path, `${JSON.stringify(event)}\n`, { mode: 0o600 });
  }

  private eventPath(sessionId: string): string {
    return join(`${this.filePath}.events`, `${encodeURIComponent(sessionId)}.jsonl`);
  }

  private async save(data: Pick<StoredSessions, "sessions" | "resolvedInteractions">): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.${process.pid}.${crypto.randomUUID()}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify(data, undefined, 2)}\n`, { mode: 0o600 });
    await rename(temporaryPath, this.filePath);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseResolvedInteractions(value: unknown): ResolvedInteraction[] {
  if (!Array.isArray(value)) throw new Error("Session store has invalid resolved interactions");
  if (value.every((interaction) => typeof interaction === "string")) return [];
  if (!value.every((interaction) =>
    isRecord(interaction) &&
    typeof interaction.interactionId === "string" &&
    typeof interaction.sequence === "number" &&
    Number.isInteger(interaction.sequence) &&
    interaction.sequence >= 0,
  )) {
    throw new Error("Session store has invalid resolved interactions");
  }
  return (value as Record<string, unknown>[]).map((interaction) => ({
    interactionId: interaction.interactionId as string,
    sequence: interaction.sequence as number,
  }));
}

function resolvedInteractionSequences(interactions: readonly ResolvedInteraction[]): Map<string, Set<number>> {
  const sequences = new Map<string, Set<number>>();
  for (const interaction of interactions) {
    const values = sequences.get(interaction.interactionId) ?? new Set<number>();
    values.add(interaction.sequence);
    sequences.set(interaction.interactionId, values);
  }
  return sequences;
}

function latestInteractionRequest(
  events: AgentEvent[],
  interactionId: string,
): Extract<AgentEvent, { type: "approval.requested" | "question.requested" }> | undefined {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    if (
      event !== undefined &&
      (event.type === "approval.requested" || event.type === "question.requested") &&
      event.interactionId === interactionId
    ) return event;
  }
  return undefined;
}

function deriveSession(session: Session, events: AgentEvent[]): Session {
  const derived = { ...session };
  for (const event of events) {
    derived.updatedAt = event.timestamp;
    if (event.type === "status") derived.status = event.status;
    else if (event.type === "approval.requested" || event.type === "question.requested") derived.status = "waiting_user";
    else if (event.type === "turn.completed") derived.status = "idle";
    else if (event.type === "session.completed") derived.status = event.outcome;
  }
  return derived;
}

function changesSessionStatus(event: AgentEvent): boolean {
  return event.type === "status" || event.type === "approval.requested" || event.type === "question.requested" || event.type === "turn.completed" || event.type === "session.completed";
}

function parseEventLog(content: string): AgentEvent[] {
  const lines = content.split("\n");
  const events: AgentEvent[] = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (line === undefined || line.length === 0) continue;
    try {
      events.push(JSON.parse(line) as AgentEvent);
    } catch (error) {
      const isTruncatedTail = index === lines.length - 1 && !content.endsWith("\n");
      if (!isTruncatedTail) throw error;
    }
  }
  return events;
}

async function rewriteEventLog(path: string, events: AgentEvent[]): Promise<void> {
  const temporaryPath = `${path}.${process.pid}.${crypto.randomUUID()}.tmp`;
  const content = events.map((event) => JSON.stringify(event)).join("\n");
  await writeFile(temporaryPath, content.length === 0 ? "" : `${content}\n`, { mode: 0o600 });
  await rename(temporaryPath, path);
}
