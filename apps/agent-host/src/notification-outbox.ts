import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { AgentEvent } from "@agentide/agent-core";
import type { NotificationCategory, Session } from "@agentide/shared-types";

export interface NotificationOutboxItem {
  cursor: number;
  projectId: string;
  sessionId: string;
  sequence: number;
  category: NotificationCategory;
  sessionTitle: string;
  createdAt: string;
}

export interface NotificationOutboxPage {
  items: NotificationOutboxItem[];
  acknowledgedCursor: number;
  latestCursor: number;
  overflowed: boolean;
  droppedThroughCursor?: number;
}

interface StoredOutbox {
  nextCursor: number;
  acknowledgedCursor: number;
  items: NotificationOutboxItem[];
  derivedSequences: Record<string, number>;
  overflowed: boolean;
  droppedThroughCursor?: number;
}

const fileMutations = new Map<string, Promise<void>>();

export class NotificationOutbox {
  constructor(
    private readonly filePath: string,
    private readonly capacity = 1_000,
  ) {}

  async enqueue(session: Session, event: AgentEvent): Promise<void> {
    await this.reconcile([session], { [session.id]: [event] });
  }

  async reconcile(sessions: readonly Session[], eventsBySession: Readonly<Record<string, readonly AgentEvent[]>>): Promise<void> {
    await this.mutate((data) => {
      let changed = false;
      let retainedItems = data.items;
      let retainedStart = 0;
      const compactAfterDroppedItems = Math.max(1, this.capacity);
      for (const session of sessions) {
        let derivedThrough = data.derivedSequences[session.id] ?? -1;
        for (const event of eventsBySession[session.id] ?? []) {
          if (event.sequence <= derivedThrough) continue;
          changed = true;
          const category = notificationCategory(event);
          if (category !== undefined) {
            retainedItems.push({
              cursor: data.nextCursor,
              projectId: session.projectId,
              sessionId: session.id,
              sequence: event.sequence,
              category,
              sessionTitle: session.title,
              createdAt: event.timestamp,
            });
            data.nextCursor += 1;
            if (retainedItems.length - retainedStart > this.capacity) {
              const dropped = retainedItems[retainedStart];
              retainedStart += 1;
              if (dropped !== undefined) {
                data.overflowed = true;
                data.droppedThroughCursor = dropped.cursor;
              }
              if (retainedStart >= compactAfterDroppedItems) {
                retainedItems = retainedItems.slice(retainedStart);
                retainedStart = 0;
              }
            }
          }
          derivedThrough = event.sequence;
        }
        if (derivedThrough >= 0) data.derivedSequences[session.id] = derivedThrough;
      }
      data.items = retainedStart === 0 ? retainedItems : retainedItems.slice(retainedStart);
      return changed;
    });
  }

  async page(afterCursor?: number, limit = 50): Promise<NotificationOutboxPage> {
    await fileMutations.get(this.filePath);
    const data = await this.readData();
    const cursor = afterCursor ?? data.acknowledgedCursor;
    return {
      items: data.items.filter((item) => item.cursor > cursor).slice(0, limit).map((item) => ({ ...item })),
      acknowledgedCursor: data.acknowledgedCursor,
      latestCursor: data.nextCursor - 1,
      overflowed: data.overflowed,
      ...(data.droppedThroughCursor === undefined ? {} : { droppedThroughCursor: data.droppedThroughCursor }),
    };
  }

  async acknowledge(cursor: number): Promise<void> {
    await this.mutate((data) => {
      if (!Number.isInteger(cursor) || cursor < data.acknowledgedCursor || cursor >= data.nextCursor) {
        throw new Error("Invalid notification outbox cursor");
      }
      data.acknowledgedCursor = cursor;
      data.items = data.items.filter((item) => item.cursor > cursor);
      if (data.droppedThroughCursor !== undefined && cursor >= data.droppedThroughCursor) {
        data.overflowed = false;
        delete data.droppedThroughCursor;
      }
      return true;
    });
  }

  private async readData(): Promise<StoredOutbox> {
    try {
      const value = JSON.parse(await readFile(this.filePath, "utf8")) as Partial<StoredOutbox>;
      if (!Number.isInteger(value.nextCursor) || !Number.isInteger(value.acknowledgedCursor) || !Array.isArray(value.items)) {
        throw new Error("Notification outbox has an invalid shape");
      }
      return {
        nextCursor: value.nextCursor as number,
        acknowledgedCursor: value.acknowledgedCursor as number,
        items: value.items as NotificationOutboxItem[],
        derivedSequences: isSequenceRecord(value.derivedSequences) ? value.derivedSequences : {},
        overflowed: value.overflowed === true,
        ...(value.droppedThroughCursor === undefined ? {} : { droppedThroughCursor: value.droppedThroughCursor }),
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      return { nextCursor: 0, acknowledgedCursor: -1, items: [], derivedSequences: {}, overflowed: false };
    }
  }

  private async mutate(operation: (data: StoredOutbox) => boolean): Promise<void> {
    const previous = fileMutations.get(this.filePath) ?? Promise.resolve();
    const result = previous.catch(() => undefined).then(async () => {
      const next = await this.readData();
      if (!operation(next)) return;
      await mkdir(dirname(this.filePath), { recursive: true });
      const temporaryPath = `${this.filePath}.${process.pid}.${crypto.randomUUID()}.tmp`;
      await writeFile(temporaryPath, `${JSON.stringify(next, undefined, 2)}\n`, { mode: 0o600 });
      await rename(temporaryPath, this.filePath);
    });
    fileMutations.set(this.filePath, result);
    try {
      await result;
    } finally {
      if (fileMutations.get(this.filePath) === result) fileMutations.delete(this.filePath);
    }
  }
}

function isSequenceRecord(value: unknown): value is Record<string, number> {
  return typeof value === "object" && value !== null && !Array.isArray(value) &&
    Object.values(value).every((sequence) => Number.isInteger(sequence) && sequence >= -1);
}

function notificationCategory(event: AgentEvent): NotificationCategory | undefined {
  if (event.type === "approval.requested") return "approval_waiting";
  if (event.type === "question.requested") return "question_waiting";
  if ((event.type === "turn.completed" || event.type === "session.completed") && event.outcome === "completed") {
    return "task_completed";
  }
  if ((event.type === "turn.completed" || event.type === "session.completed") && event.outcome === "failed") {
    return "task_failed";
  }
  return undefined;
}
