import { homedir } from "node:os";
import { join } from "node:path";
import type { AgentAdapter, AgentEvent, AgentInput, InteractionResponse } from "@agentide/agent-core";
import type { AgentType, Session } from "@agentide/shared-types";
import { CodexAdapter } from "@agentide/agent-codex";
import { ProjectStore } from "./project-store.js";
import { SessionStore } from "./session-store.js";

export interface CreateManagedSession {
  projectId: string;
  agentType: AgentType;
  initialPrompt?: string;
}

export class SessionManager {
  private readonly runtimeIds = new Map<string, string>();
  private readonly pumps = new Map<string, Promise<void>>();
  private readonly loads = new Map<string, Promise<{ adapter: AgentAdapter; runtimeId: string }>>();
  private readonly operations = new Map<string, Promise<void>>();
  private readonly expiredInteractions = new Map<string, Set<string>>();
  private reconciliation: Promise<void> | undefined;

  constructor(
    private readonly projects: ProjectStore,
    private readonly store: SessionStore,
    private readonly adapters: ReadonlyMap<AgentType, AgentAdapter>,
  ) {}

  static local(projects: ProjectStore): SessionManager {
    const dataDirectory = process.env.AGENTIDE_DATA_DIR ?? join(homedir(), "Library", "Application Support", "AgentIDE");
    return new SessionManager(
      projects,
      new SessionStore(join(dataDirectory, "sessions.json")),
      new Map<AgentType, AgentAdapter>([["codex", new CodexAdapter()]]),
    );
  }

  async list(projectId?: string): Promise<Session[]> {
    await this.ensureReconciled();
    return this.store.list(projectId);
  }

  async get(sessionId: string): Promise<Session> {
    await this.ensureReconciled();
    const session = await this.store.get(sessionId);
    if (session === undefined) throw new Error("Session not found");
    return session;
  }

  async events(sessionId: string, afterSequence?: number): Promise<AgentEvent[]> {
    await this.get(sessionId);
    return this.store.events(sessionId, afterSequence);
  }

  async create(input: CreateManagedSession): Promise<Session> {
    await this.ensureReconciled();
    const project = await this.projects.get(input.projectId);
    if (project === undefined) throw new Error("Project not found");
    if (!project.enabledAgents.includes(input.agentType)) throw new Error(`${input.agentType} is not available for this project`);
    const adapter = this.requireAdapter(input.agentType);
    const sessionId = crypto.randomUUID();
    const session = await adapter.createSession({
      sessionId,
      projectId: project.id,
      workingDirectory: project.rootPath,
    });
    if (input.initialPrompt !== undefined) session.title = titleFor(input.initialPrompt);
    await this.store.create(session);
    this.attach(session.id, adapter, session.id);
    if (input.initialPrompt !== undefined) {
      try {
        await this.sendAndWaitForPersistence(session.id, adapter, session.id, { content: input.initialPrompt });
      } catch { /* The adapter publishes the normalized failure before rejecting the operation. */ }
    }
    return this.get(session.id);
  }

  async sendMessage(sessionId: string, input: AgentInput): Promise<void> {
    await this.run(sessionId, async () => {
      const { adapter, runtimeId } = await this.load(sessionId);
      await this.sendAndWaitForPersistence(sessionId, adapter, runtimeId, input);
      this.expiredInteractions.delete(sessionId);
    });
  }

  async cancel(sessionId: string): Promise<void> {
    await this.run(sessionId, async () => {
      const { adapter, runtimeId } = await this.load(sessionId);
      await adapter.cancel(runtimeId);
    });
  }

  async respond(sessionId: string, interactionId: string, response: InteractionResponse): Promise<void> {
    await this.ensureReconciled();
    await this.run(sessionId, async () => {
      if (this.expiredInteractions.get(sessionId)?.has(interactionId) === true) {
        throw new Error("Interaction expired when Agent Host restarted");
      }
      const { adapter, runtimeId } = await this.load(sessionId);
      await adapter.respondToInteraction(runtimeId, interactionId, response);
    });
  }

  private async load(sessionId: string): Promise<{ adapter: AgentAdapter; runtimeId: string }> {
    const pending = this.loads.get(sessionId);
    if (pending !== undefined) return pending;
    const loading = this.loadOnce(sessionId);
    this.loads.set(sessionId, loading);
    try { return await loading; } finally { this.loads.delete(sessionId); }
  }

  private async loadOnce(sessionId: string): Promise<{ adapter: AgentAdapter; runtimeId: string }> {
    const session = await this.get(sessionId);
    const adapter = this.requireAdapter(session.agentType);
    const loaded = this.runtimeIds.get(sessionId);
    if (loaded !== undefined) return { adapter, runtimeId: loaded };
    if (session.nativeSessionId === undefined) throw new Error("Session has no native session id");
    const project = await this.projects.get(session.projectId);
    if (project === undefined) throw new Error("Project not found");
    const resumed = await adapter.resumeSession(session.nativeSessionId, project.rootPath);
    this.attach(sessionId, adapter, resumed.id);
    return { adapter, runtimeId: resumed.id };
  }

  async close(): Promise<void> {
    for (const adapter of new Set(this.adapters.values())) {
      if ("close" in adapter && typeof adapter.close === "function") await adapter.close();
    }
    await Promise.allSettled(this.pumps.values());
  }

  private attach(sessionId: string, adapter: AgentAdapter, runtimeId: string): void {
    this.runtimeIds.set(sessionId, runtimeId);
    if (this.pumps.has(sessionId)) return;
    const pump = this.pump(sessionId, adapter, runtimeId);
    this.pumps.set(sessionId, pump);
    void pump.then(
      () => this.pumps.delete(sessionId),
      (error) => {
        this.pumps.delete(sessionId);
        console.error("Agent event pump stopped", error);
      },
    );
  }

  private async pump(sessionId: string, adapter: AgentAdapter, runtimeId: string): Promise<void> {
    try {
      for await (const event of adapter.events(runtimeId)) await this.store.record(sessionId, event);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Agent event stream failed";
      await this.store.record(sessionId, {
        id: crypto.randomUUID(),
        sessionId,
        sequence: 0,
        timestamp: new Date().toISOString(),
        type: "error",
        code: "agent_event_stream_failed",
        message,
        recoverable: true,
      });
    }
  }

  private requireAdapter(type: AgentType): AgentAdapter {
    const adapter = this.adapters.get(type);
    if (adapter === undefined) throw new Error(`Agent adapter is not configured: ${type}`);
    return adapter;
  }

  private async run<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.operations.get(sessionId) ?? Promise.resolve();
    let result!: T;
    const current = previous.catch(() => undefined).then(async () => { result = await operation(); });
    this.operations.set(sessionId, current);
    try {
      await current;
      return result;
    } finally {
      if (this.operations.get(sessionId) === current) this.operations.delete(sessionId);
    }
  }

  private async recordFailure(sessionId: string, code: string, error: unknown): Promise<void> {
    const message = error instanceof Error ? error.message : "Agent operation failed";
    const timestamp = new Date().toISOString();
    await this.store.record(sessionId, {
      id: crypto.randomUUID(), sessionId, sequence: 0, timestamp,
      type: "error", code, message, recoverable: true,
    });
    await this.store.record(sessionId, {
      id: crypto.randomUUID(), sessionId, sequence: 0, timestamp,
      type: "turn.completed", outcome: "failed",
    });
  }

  private async sendAndWaitForPersistence(
    sessionId: string,
    adapter: AgentAdapter,
    runtimeId: string,
    input: AgentInput,
  ): Promise<void> {
    const previousEvents = await this.store.events(sessionId);
    const afterSequence = previousEvents.at(-1)?.sequence ?? -1;
    await adapter.sendMessage(runtimeId, input);
    await this.store.waitForEvent(
      sessionId,
      afterSequence,
      (event) => event.type === "status" && event.status === "running",
    );
  }

  private async ensureReconciled(): Promise<void> {
    this.reconciliation ??= this.reconcileInterruptedInteractions();
    return this.reconciliation;
  }

  private async reconcileInterruptedInteractions(): Promise<void> {
    const sessions = await this.store.list();
    for (const session of sessions) {
      if (session.status === "waiting_user") {
        const events = await this.store.events(session.id);
        const interactionIds = events
          .filter((event): event is Extract<AgentEvent, { type: "approval.requested" }> => event.type === "approval.requested")
          .map((event) => event.interactionId);
        this.expiredInteractions.set(session.id, new Set(interactionIds));
        await this.recordFailure(session.id, "agent_interaction_expired", new Error("Pending interaction expired when Agent Host restarted"));
      }
    }
  }
}

function titleFor(prompt: string): string {
  const value = prompt.trim();
  if (value.length === 0) return "New session";
  return value.length <= 80 ? value : `${value.slice(0, 77)}...`;
}
