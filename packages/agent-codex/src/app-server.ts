import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface, type Interface } from "node:readline";

export interface CodexNotification {
  method: string;
  params: unknown;
}

export interface CodexServerRequest extends CodexNotification {
  id: string | number;
}

export interface CodexAppServerConnection {
  start(): Promise<void>;
  stop(): Promise<void>;
  request(method: string, params: unknown): Promise<unknown>;
  respond(id: string | number, result: unknown): void;
  respondError(id: string | number, code: number, message: string): void;
  onNotification(listener: (notification: CodexNotification) => void): void;
  onServerRequest(listener: (request: CodexServerRequest) => void): void;
  onError(listener: (error: Error) => void): void;
}

interface PendingRequest {
  resolve(value: unknown): void;
  reject(error: Error): void;
}

export class SpawnedCodexAppServer implements CodexAppServerConnection {
  private process: ChildProcessWithoutNullStreams | undefined;
  private starting: Promise<void> | undefined;
  private lines: Interface | undefined;
  private nextId = 1;
  private stderr = "";
  private readonly pending = new Map<number, PendingRequest>();
  private readonly notificationListeners = new Set<(notification: CodexNotification) => void>();
  private readonly requestListeners = new Set<(request: CodexServerRequest) => void>();
  private readonly errorListeners = new Set<(error: Error) => void>();

  constructor(
    private readonly executable = "codex",
    private readonly environment: NodeJS.ProcessEnv = process.env,
  ) {}

  async start(): Promise<void> {
    if (this.starting !== undefined) {
      await this.starting;
      return;
    }
    if (this.process !== undefined) return;
    this.starting ??= this.startOnce();
    try { await this.starting; } finally { this.starting = undefined; }
  }

  private async startOnce(): Promise<void> {
    const child = spawn(this.executable, ["app-server"], {
      env: this.environment,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.process = child;
    this.stderr = "";
    child.stderr.on("data", (chunk: Buffer) => {
      this.stderr = `${this.stderr}${chunk.toString("utf8")}`.slice(-8_192);
    });
    child.stdin.on("error", (cause) => this.handleProcessFailure(child, new Error(`Codex app-server stdin failed: ${cause.message}`)));
    child.once("error", (cause) => this.handleProcessFailure(child, new Error(`Unable to start Codex app-server: ${cause.message}`)));
    child.once("exit", (code, signal) => {
      const detail = signal === null ? `exit code ${String(code)}` : `signal ${signal}`;
      const diagnostic = this.stderr.trim();
      this.handleProcessFailure(child, new Error(`Codex app-server stopped with ${detail}${diagnostic.length === 0 ? "" : `: ${diagnostic}`}`));
    });
    this.lines = createInterface({ input: child.stdout });
    this.lines.on("line", (line) => this.handleLine(line));
    try {
      await this.request("initialize", {
        clientInfo: { name: "agentide", title: "AgentIDE", version: "0.1.0" },
        capabilities: { experimentalApi: false, requestAttestation: false },
      });
      this.write({ method: "initialized", params: {} });
    } catch (error) {
      this.discard(child);
      throw error;
    }
  }

  async stop(): Promise<void> {
    const child = this.process;
    if (child === undefined) return;
    this.process = undefined;
    this.lines?.close();
    this.lines = undefined;
    child.kill("SIGTERM");
    this.failAll(new Error("Codex app-server stopped"));
  }

  async request(method: string, params: unknown): Promise<unknown> {
    if (this.process === undefined && method !== "initialize") await this.start();
    const id = this.nextId;
    this.nextId += 1;
    const result = new Promise<unknown>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
    this.write({ method, id, params });
    return result;
  }

  respond(id: string | number, result: unknown): void {
    this.write({ id, result });
  }

  respondError(id: string | number, code: number, message: string): void {
    this.write({ id, error: { code, message } });
  }

  onNotification(listener: (notification: CodexNotification) => void): void {
    this.notificationListeners.add(listener);
  }

  onServerRequest(listener: (request: CodexServerRequest) => void): void {
    this.requestListeners.add(listener);
  }

  onError(listener: (error: Error) => void): void {
    this.errorListeners.add(listener);
  }

  private write(message: unknown): void {
    if (this.process === undefined) throw new Error("Codex app-server is not running");
    this.process.stdin.write(`${JSON.stringify(message)}\n`);
  }

  private handleLine(line: string): void {
    let value: unknown;
    try { value = JSON.parse(line); } catch { return; }
    if (!isRecord(value)) return;
    if (value.id !== undefined && (typeof value.id === "number" || typeof value.id === "string")) {
      if (typeof value.method === "string") {
        const request = { id: value.id, method: value.method, params: value.params };
        for (const listener of this.requestListeners) listener(request);
        return;
      }
      if (typeof value.id !== "number") return;
      const pending = this.pending.get(value.id);
      if (pending === undefined) return;
      this.pending.delete(value.id);
      if (isRecord(value.error)) {
        pending.reject(new Error(typeof value.error.message === "string" ? value.error.message : "Codex request failed"));
      } else pending.resolve(value.result);
      return;
    }
    if (typeof value.method !== "string") return;
    const notification = { method: value.method, params: value.params };
    for (const listener of this.notificationListeners) listener(notification);
  }

  private failAll(error: Error): void {
    for (const request of this.pending.values()) request.reject(error);
    this.pending.clear();
  }

  private handleProcessFailure(child: ChildProcessWithoutNullStreams, error: Error): void {
    if (this.process !== child) return;
    this.process = undefined;
    this.lines?.close();
    this.lines = undefined;
    this.failAll(error);
    for (const listener of this.errorListeners) listener(error);
  }

  private discard(child: ChildProcessWithoutNullStreams): void {
    if (this.process !== child) return;
    this.process = undefined;
    this.lines?.close();
    this.lines = undefined;
    this.failAll(new Error("Codex app-server initialization failed"));
    child.kill("SIGTERM");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
