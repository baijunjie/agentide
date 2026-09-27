import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { FileSearchError, LocalFileService } from "./file-service.js";
import { GitServiceError, LocalGitService } from "./git-service.js";
import { ProjectStore } from "./project-store.js";
import { SessionManager } from "./session-manager.js";

export interface AgentHostServerOptions {
  authenticationToken?: string;
}

export function createAgentHostServer(
  projects = new ProjectStore(),
  sessions = SessionManager.local(projects),
  options: AgentHostServerOptions = {},
) {
  const files = new LocalFileService(projects);
  const searches = new FileSearchTasks();
  const git = new LocalGitService(projects);
  return createServer((request, response) => {
    if (!isAuthorized(request, options.authenticationToken)) {
      sendJSON(response, 401, { error: "Unauthorized" });
      return;
    }
    void route(request, response, projects, files, searches, git, sessions).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : "Unexpected error";
      sendJSON(response, statusFor(error), { error: message, code: errorCode(error) });
    });
  });
}

function isAuthorized(request: IncomingMessage, token: string | undefined): boolean {
  if (token === undefined) return true;
  return request.headers.authorization === `Bearer ${token}`;
}

async function route(
  request: IncomingMessage,
  response: ServerResponse,
  projects: ProjectStore,
  files: LocalFileService,
  searches: FileSearchTasks,
  git: LocalGitService,
  sessions: SessionManager,
): Promise<void> {
  const url = new URL(request.url ?? "/", "http://127.0.0.1");
  if (request.method === "GET" && url.pathname === "/health") {
    sendJSON(response, 200, { status: "ok" });
    return;
  }
  if (request.method === "GET" && url.pathname === "/projects") {
    sendJSON(response, 200, { projects: await projects.list() });
    return;
  }
  if (request.method === "POST" && url.pathname === "/projects") {
    const body = await readJSON(request);
    sendJSON(response, 201, await projects.add(requireString(body, "rootPath"), optionalString(body, "name")));
    return;
  }
  if (url.pathname === "/sessions" && request.method === "GET") {
    const projectId = url.searchParams.get("projectId") ?? undefined;
    sendJSON(response, 200, { sessions: await sessions.list(projectId) });
    return;
  }
  if (url.pathname === "/sessions" && request.method === "POST") {
    const body = await readJSON(request);
    const agentType = requireString(body, "agentType");
    if (agentType !== "codex" && agentType !== "claude") throw new Error("agentType must be codex or claude");
    const initialPrompt = optionalString(body, "initialPrompt");
    sendJSON(response, 201, await sessions.create({
      projectId: requireString(body, "projectId"),
      agentType,
      ...(initialPrompt === undefined ? {} : { initialPrompt }),
    }));
    return;
  }

  const sessionMatch = /^\/sessions\/([^/]+)$/.exec(url.pathname);
  if (sessionMatch !== null && request.method === "GET") {
    sendJSON(response, 200, await sessions.get(decodeURIComponent(sessionMatch[1] ?? "")));
    return;
  }
  const sessionOperationMatch = /^\/sessions\/([^/]+)\/(events|messages|cancel|interactions|snapshot)$/.exec(url.pathname);
  if (sessionOperationMatch !== null) {
    const sessionId = decodeURIComponent(sessionOperationMatch[1] ?? "");
    const operation = sessionOperationMatch[2];
    if (operation === "snapshot" && request.method === "GET") {
      sendJSON(response, 200, await sessions.snapshot(sessionId));
      return;
    }
    if (operation === "events" && request.method === "GET") {
      const afterValue = url.searchParams.get("afterSequence");
      const afterSequence = afterValue === null ? undefined : Number(afterValue);
      if (afterSequence !== undefined && !Number.isInteger(afterSequence)) throw new Error("afterSequence must be an integer");
      sendJSON(response, 200, { events: await sessions.events(sessionId, afterSequence) });
      return;
    }
    if (operation === "messages" && request.method === "POST") {
      await sessions.sendMessage(sessionId, { content: requireString(await readJSON(request), "content") });
      response.writeHead(204).end();
      return;
    }
    if (operation === "cancel" && request.method === "POST") {
      await sessions.cancel(sessionId);
      response.writeHead(204).end();
      return;
    }
    if (operation === "interactions" && request.method === "POST") {
      const body = await readJSON(request);
      const kind = requireString(body, "kind");
      const interactionId = requireString(body, "interactionId");
      if (kind === "approval") {
        const action = requireString(body, "action");
        if (action !== "approve_once" && action !== "approve_session" && action !== "reject") {
          throw new Error("Invalid approval action");
        }
        await sessions.respond(sessionId, interactionId, { kind, action });
      } else if (kind === "question") {
        const optionIds = optionalStringArray(body, "optionIds");
        const freeText = optionalString(body, "freeText");
        if (optionIds === undefined && freeText === undefined) throw new Error("Question response must include optionIds or freeText");
        await sessions.respond(sessionId, interactionId, {
          kind,
          ...(optionIds === undefined ? {} : { optionIds }),
          ...(freeText === undefined ? {} : { freeText }),
        });
      } else {
        throw new Error("Interaction kind must be approval or question");
      }
      response.writeHead(204).end();
      return;
    }
  }

  const projectMatch = /^\/projects\/([^/]+)$/.exec(url.pathname);
  if (projectMatch !== null && request.method === "PATCH") {
    sendJSON(response, 200, await projects.rename(decodeURIComponent(projectMatch[1] ?? ""), requireString(await readJSON(request), "name")));
    return;
  }
  if (projectMatch !== null && request.method === "DELETE") {
    await projects.remove(decodeURIComponent(projectMatch[1] ?? ""));
    response.writeHead(204).end();
    return;
  }

  const fileMatch = /^\/projects\/([^/]+)\/files\/(list|read-text|read-binary|list-images|search|cancel-search)$/.exec(url.pathname);
  if (fileMatch !== null && request.method === "POST") {
    const projectId = decodeURIComponent(fileMatch[1] ?? "");
    const operation = fileMatch[2];
    const body = await readJSON(request);
    if (operation === "search") {
      const searchId = requireString(body, "searchId");
      sendJSON(response, 200, await searches.run(searchId, (signal) => files.search(
        projectId,
        searchId,
        requireString(body, "query"),
        requireInteger(body, "limit"),
        signal,
      )));
      return;
    }
    if (operation === "cancel-search") {
      searches.cancel(requireString(body, "searchId"));
      response.writeHead(204).end();
      return;
    }
    const relativePath = requireString(body, "relativePath", true);
    if (operation === "list") sendJSON(response, 200, { entries: await files.list(projectId, relativePath) });
    else if (operation === "read-text") sendJSON(response, 200, { content: await files.readText(projectId, relativePath) });
    else if (operation === "read-binary") {
      const content = Buffer.from(await files.readBinary(projectId, relativePath)).toString("base64");
      sendJSON(response, 200, { content });
    } else sendJSON(response, 200, { entries: await files.listSiblingImages(projectId, relativePath) });
    return;
  }

  const gitMatch = /^\/projects\/([^/]+)\/(changes|diff)$/.exec(url.pathname);
  if (gitMatch !== null && request.method === "POST") {
    const projectId = decodeURIComponent(gitMatch[1] ?? "");
    if (gitMatch[2] === "changes") {
      sendJSON(response, 200, await git.listChanges(projectId));
    } else {
      const body = await readJSON(request);
      const area = requireString(body, "area");
      if (area !== "staged" && area !== "unstaged") throw new Error("area must be staged or unstaged");
      sendJSON(response, 200, await git.readDiff(projectId, requireString(body, "relativePath"), area));
    }
    return;
  }

  sendJSON(response, 404, { error: "Not found" });
}

async function readJSON(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.from(chunk);
    size += buffer.length;
    if (size > 1024 * 1024) throw new Error("Request body is too large");
    chunks.push(buffer);
  }
  const value: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Request body must be an object");
  return value as Record<string, unknown>;
}

function requireString(body: Record<string, unknown>, key: string, allowEmpty = false): string {
  const value = body[key];
  if (typeof value !== "string" || (!allowEmpty && value.trim().length === 0)) throw new Error(`${key} must be a string`);
  return value;
}

function optionalString(body: Record<string, unknown>, key: string): string | undefined {
  const value = body[key];
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new Error(`${key} must be a string`);
  return value;
}

function optionalStringArray(body: Record<string, unknown>, key: string): string[] | undefined {
  const value = body[key];
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
    throw new Error(`${key} must be an array of strings`);
  }
  return value;
}

function requireInteger(body: Record<string, unknown>, key: string): number {
  const value = body[key];
  if (!Number.isInteger(value)) throw new Error(`${key} must be an integer`);
  return value as number;
}

function statusFor(error: unknown): number {
  if (error instanceof FileSearchError && error.code === "search_cancelled") return 499;
  if (error instanceof FileSearchError && error.code === "search_busy") return 503;
  if (error instanceof GitServiceError && error.code === "git_timeout") return 408;
  if (error instanceof GitServiceError && error.code === "git_output_too_large") return 413;
  if (error instanceof GitServiceError && error.code === "git_busy") return 503;
  const message = error instanceof Error ? error.message : "";
  if (message === "Project not found" || message === "Session not found") return 404;
  if (message === "Project is already registered") return 409;
  if (message.includes("ENOENT")) return 404;
  return 400;
}

function errorCode(error: unknown): string {
  if (error instanceof GitServiceError || error instanceof FileSearchError) return error.code;
  return "request_failed";
}

function sendJSON(response: ServerResponse, status: number, value: unknown): void {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(value));
}

export class FileSearchTasks {
  private static readonly maxConcurrent = 4;
  private static readonly tombstoneTtlMs = 30_000;
  private static readonly maxTombstones = 1_024;
  private readonly active = new Map<string, AbortController>();
  private readonly cancelled = new Map<string, number>();

  async run<T>(searchId: string, operation: (signal: AbortSignal) => Promise<T>): Promise<T> {
    this.pruneCancelled();
    if (this.cancelled.delete(searchId)) {
      throw new FileSearchError("search_cancelled", "Search was cancelled before it started");
    }
    if (this.active.has(searchId)) {
      throw new FileSearchError("search_invalid_request", "searchId is already active");
    }
    if (this.active.size >= FileSearchTasks.maxConcurrent) {
      throw new FileSearchError("search_busy", "Too many file searches are active");
    }
    const controller = new AbortController();
    this.active.set(searchId, controller);
    try {
      return await operation(controller.signal);
    } finally {
      if (this.active.get(searchId) === controller) this.active.delete(searchId);
    }
  }

  cancel(searchId: string): void {
    const controller = this.active.get(searchId);
    if (controller !== undefined) {
      controller.abort();
      return;
    }
    this.pruneCancelled();
    this.cancelled.set(searchId, Date.now() + FileSearchTasks.tombstoneTtlMs);
    while (this.cancelled.size > FileSearchTasks.maxTombstones) {
      const oldest = this.cancelled.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.cancelled.delete(oldest);
    }
  }

  private pruneCancelled(): void {
    const now = Date.now();
    for (const [searchId, expiresAt] of this.cancelled) {
      if (expiresAt > now) continue;
      this.cancelled.delete(searchId);
    }
  }
}
