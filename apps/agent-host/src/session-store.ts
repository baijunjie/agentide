import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { AgentEvent } from "@agentide/agent-core";
import type { Session } from "@agentide/shared-types";

interface StoredSessions {
  sessions: Session[];
  events: Record<string, AgentEvent[]>;
}

export class SessionStore {
  private data: StoredSessions | undefined;
  private loading: Promise<void> | undefined;
  private mutations: Promise<void> = Promise.resolve();
  private readonly eventWaiters = new Map<string, Set<(event: AgentEvent) => void>>();

  constructor(private readonly filePath: string) {}

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

  async create(session: Session): Promise<void> {
    await this.mutate(async (data) => {
      if (data.sessions.some((value) => value.id === session.id)) throw new Error("Session already exists");
      data.sessions.push({ ...session });
      data.events[session.id] = [];
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
      if (stored.type === "status") nextSession.status = stored.status;
      else if (stored.type === "approval.requested" || stored.type === "question.requested") nextSession.status = "waiting_user";
      else if (stored.type === "turn.completed") nextSession.status = "idle";
      else if (stored.type === "session.completed") nextSession.status = stored.outcome;
      const sessions = [...data.sessions];
      sessions[sessionIndex] = nextSession;
      try {
        await this.appendEvent(sessionId, stored);
        if (changesSessionStatus(stored)) await this.save(sessions);
      } catch (error) {
        this.data = undefined;
        this.loading = undefined;
        throw error;
      }
      events.push(stored);
      data.events[sessionId] = events;
      data.sessions = sessions;
      for (const notify of this.eventWaiters.get(sessionId) ?? []) notify(stored);
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
      if (!isRecord(value) || !Array.isArray(value.sessions) || (value.events !== undefined && !isRecord(value.events))) {
        throw new Error("Session store has an invalid shape");
      }
      const sessions = value.sessions as Session[];
      const legacy = isRecord(value.events) ? value.events as Record<string, AgentEvent[]> : {};
      const eventEntries = await Promise.all(sessions.map(async (session) => {
        let persisted: AgentEvent[] = [];
        try {
          const path = this.eventPath(session.id);
          const content = await readFile(path, "utf8");
          persisted = parseEventLog(content);
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
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      this.data = { sessions: [], events: {} };
    }
  }

  private async mutate(operation: (data: StoredSessions) => Promise<void>): Promise<void> {
    await this.load();
    const result = this.mutations.then(async () => {
      const current = this.data;
      if (current === undefined) throw new Error("Session store failed to load");
      const next = structuredClone(current);
      await operation(next);
      await this.save(next.sessions);
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

  private async save(sessions: Session[]): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.${process.pid}.${crypto.randomUUID()}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify({ sessions }, undefined, 2)}\n`, { mode: 0o600 });
    await rename(temporaryPath, this.filePath);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
