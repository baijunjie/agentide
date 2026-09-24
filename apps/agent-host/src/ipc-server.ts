import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { LocalFileService } from "./file-service.js";
import { ProjectStore } from "./project-store.js";
import { SessionManager } from "./session-manager.js";

export function createAgentHostServer(
  projects = new ProjectStore(),
  sessions = SessionManager.local(projects),
) {
  const files = new LocalFileService(projects);
  return createServer((request, response) => {
    void route(request, response, projects, files, sessions).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : "Unexpected error";
      sendJSON(response, statusFor(message), { error: message });
    });
  });
}

async function route(
  request: IncomingMessage,
  response: ServerResponse,
  projects: ProjectStore,
  files: LocalFileService,
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
  const sessionOperationMatch = /^\/sessions\/([^/]+)\/(events|messages|cancel|interactions)$/.exec(url.pathname);
  if (sessionOperationMatch !== null) {
    const sessionId = decodeURIComponent(sessionOperationMatch[1] ?? "");
    const operation = sessionOperationMatch[2];
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
      if (kind !== "approval") throw new Error("Only approval interactions are supported");
      const action = requireString(body, "action");
      if (action !== "approve_once" && action !== "approve_session" && action !== "reject") {
        throw new Error("Invalid approval action");
      }
      await sessions.respond(sessionId, requireString(body, "interactionId"), { kind, action });
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

  const fileMatch = /^\/projects\/([^/]+)\/files\/(list|read-text|read-binary|list-images)$/.exec(url.pathname);
  if (fileMatch !== null && request.method === "POST") {
    const projectId = decodeURIComponent(fileMatch[1] ?? "");
    const operation = fileMatch[2];
    const relativePath = requireString(await readJSON(request), "relativePath", true);
    if (operation === "list") sendJSON(response, 200, { entries: await files.list(projectId, relativePath) });
    else if (operation === "read-text") sendJSON(response, 200, { content: await files.readText(projectId, relativePath) });
    else if (operation === "read-binary") {
      const content = Buffer.from(await files.readBinary(projectId, relativePath)).toString("base64");
      sendJSON(response, 200, { content });
    } else sendJSON(response, 200, { entries: await files.listSiblingImages(projectId, relativePath) });
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

function statusFor(message: string): number {
  if (message === "Project not found" || message === "Session not found") return 404;
  if (message === "Project is already registered") return 409;
  if (message.includes("ENOENT")) return 404;
  return 400;
}

function sendJSON(response: ServerResponse, status: number, value: unknown): void {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(value));
}
