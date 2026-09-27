import { spawn } from "node:child_process";
import { extname } from "node:path";
import { fileURLToPath } from "node:url";
import type { FileEntry, ProjectSearchFilesResponse } from "@agentide/shared-types";
import type { ProjectStore } from "./project-store.js";
import { unicodeDefaultCaseFold } from "./unicode-case-folding.js";

const HELPER_PATH = fileURLToPath(new URL("./native/file-access", import.meta.url));
const IGNORED_NAMES = new Set([".git", "node_modules", "DerivedData", ".build", "Pods"]);
const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "heic", "webp"]);
const TEXT_EXTENSIONS = new Set([
  "c", "cc", "cpp", "css", "h", "hpp", "html", "java", "js", "json", "jsx", "kt", "md",
  "m", "mm", "py", "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml",
  "yaml", "yml",
]);

const DEFAULT_SEARCH_LIMITS = {
  traversedEntries: 50_000,
  timeoutMs: 5_000,
  responseBytes: 700 * 1024,
} as const;
const MAX_SEARCH_ID_LENGTH = 128;
const MAX_SEARCH_QUERY_LENGTH = 256;
const SEARCH_EDGE_WHITESPACE = /^[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]|[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]$/u;

export type FileSearchErrorCode = "search_busy" | "search_cancelled" | "search_invalid_request";

export class FileSearchError extends Error {
  constructor(readonly code: FileSearchErrorCode, message: string) {
    super(message);
    this.name = "FileSearchError";
  }
}

export interface FileSearchLimits {
  traversedEntries: number;
  timeoutMs: number;
  responseBytes: number;
}

export class LocalFileService {
  constructor(
    private readonly projects: ProjectStore,
    private readonly searchLimits: FileSearchLimits = DEFAULT_SEARCH_LIMITS,
  ) {}

  async list(projectId: string, relativePath: string): Promise<FileEntry[]> {
    const path = normalizeRelativePath(relativePath);
    const output = await this.run(projectId, "list", path);
    return parseEntries(output, path).sort((left, right) => left.type === right.type
      ? left.name.localeCompare(right.name)
      : left.type === "directory" ? -1 : 1);
  }

  async readText(projectId: string, relativePath: string): Promise<string> {
    const data = await this.run(projectId, "read", normalizeRelativePath(relativePath, false));
    if (data.includes(0)) throw new Error("File is not text");
    return data.toString("utf8");
  }

  async readBinary(projectId: string, relativePath: string): Promise<Uint8Array> {
    return this.run(projectId, "read", normalizeRelativePath(relativePath, false));
  }

  async listSiblingImages(projectId: string, relativePath: string): Promise<FileEntry[]> {
    const path = normalizeRelativePath(relativePath, false);
    const separator = path.lastIndexOf("/");
    const parent = separator < 0 ? "" : path.slice(0, separator);
    return (await this.list(projectId, parent)).filter((entry) => entry.type === "file" && entry.isImage === true);
  }

  async search(
    projectId: string,
    searchId: string,
    query: string,
    limit: number,
    signal: AbortSignal,
  ): Promise<ProjectSearchFilesResponse> {
    const normalizedQuery = normalizeSearchValue(query);
    const queryLength = Array.from(query).length;
    const searchIdLength = Array.from(searchId).length;
    if (searchIdLength === 0 || searchIdLength > MAX_SEARCH_ID_LENGTH || SEARCH_EDGE_WHITESPACE.test(query)
      || queryLength < 2 || queryLength > MAX_SEARCH_QUERY_LENGTH || !Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new FileSearchError("search_invalid_request", "Search requires a non-empty id, at least two characters, and a limit from 1 to 100");
    }

    const deadline = Date.now() + this.searchLimits.timeoutMs;
    const directories = [""];
    let directoryIndex = 0;
    const candidates: FileEntry[] = [];
    let traversedEntries = 0;
    let matchingEntries = 0;
    let truncated = false;

    while (directoryIndex < directories.length) {
      assertNotCancelled(signal);
      if (Date.now() >= deadline || traversedEntries >= this.searchLimits.traversedEntries) {
        truncated = true;
        break;
      }
      const directory = directories[directoryIndex] ?? "";
      directoryIndex += 1;
      let listing: { entries: FileEntry[]; truncated: boolean };
      try {
        listing = await this.listWithSignal(
          projectId,
          directory,
          signal,
          deadline - Date.now(),
          this.searchLimits.traversedEntries - traversedEntries,
        );
      } catch (error) {
        if (error instanceof FileSearchDeadlineError) {
          truncated = true;
          break;
        }
        if (directory.length > 0 && error instanceof NativeFileAccessError && [11, 12, 13].includes(error.exitCode ?? -1)) {
          truncated = true;
          continue;
        }
        throw error;
      }
      for (const entry of listing.entries) {
        if (Date.now() >= deadline) {
          truncated = true;
          break;
        }
        traversedEntries += 1;
        if (entry.type === "directory") directories.push(entry.relativePath);
        if (matchesSearch(entry, normalizedQuery)) {
          matchingEntries += 1;
          candidates.push(entry);
          candidates.sort((left, right) => compareSearchResults(left, right, normalizedQuery));
          if (candidates.length > limit) candidates.pop();
        }
        if (traversedEntries >= this.searchLimits.traversedEntries) {
          truncated = listing.truncated || directoryIndex < directories.length || listing.entries.at(-1) !== entry;
          break;
        }
      }
      if (listing.truncated) {
        truncated = true;
        break;
      }
    }

    const response: ProjectSearchFilesResponse = {
      searchId,
      query,
      results: candidates,
      hasMore: truncated || matchingEntries > candidates.length,
    };
    while (response.results.length > 0 && Buffer.byteLength(JSON.stringify(response), "utf8") > this.searchLimits.responseBytes) {
      candidates.pop();
      response.hasMore = true;
    }
    if (Buffer.byteLength(JSON.stringify(response), "utf8") > this.searchLimits.responseBytes) {
      throw new FileSearchError("search_invalid_request", "Search metadata exceeds the response limit");
    }
    return response;
  }

  private async listWithSignal(
    projectId: string,
    relativePath: string,
    signal: AbortSignal,
    timeoutMs: number,
    maxEntries: number,
  ): Promise<{ entries: FileEntry[]; truncated: boolean }> {
    const path = normalizeRelativePath(relativePath);
    const result = await this.runWithOptions(projectId, "list", path, { signal, timeoutMs, maxRecords: maxEntries });
    return {
      entries: parseEntries(result.output, path).sort((left, right) => left.type === right.type
        ? left.name.localeCompare(right.name)
        : left.type === "directory" ? -1 : 1),
      truncated: result.truncated,
    };
  }

  private async run(
    projectId: string,
    operation: "list" | "read",
    relativePath: string,
    signal?: AbortSignal,
    timeoutMs?: number,
  ): Promise<Buffer> {
    return (await this.runWithOptions(projectId, operation, relativePath, { signal, timeoutMs })).output;
  }

  private async runWithOptions(
    projectId: string,
    operation: "list" | "read",
    relativePath: string,
    options: { signal?: AbortSignal | undefined; timeoutMs?: number | undefined; maxRecords?: number | undefined },
  ): Promise<{ output: Buffer; truncated: boolean }> {
    const project = await this.projects.get(projectId);
    if (project === undefined) throw new Error("Project not found");
    if (options.signal?.aborted === true) throw new FileSearchError("search_cancelled", "Search was cancelled");
    return new Promise<{ output: Buffer; truncated: boolean }>((resolve, reject) => {
      const process = spawn(HELPER_PATH, [operation, project.rootPath, relativePath], { stdio: ["ignore", "pipe", "pipe"] });
      const output: Buffer[] = [];
      const errors: Buffer[] = [];
      let timedOut = false;
      let truncated = false;
      let outputBytes = 0;
      let errorBytes = 0;
      let recordCount = 0;
      let acceptedBytes: number | undefined;
      const abort = () => process.kill("SIGTERM");
      const timeout = options.timeoutMs === undefined ? undefined : setTimeout(() => {
        timedOut = true;
        process.kill("SIGTERM");
      }, Math.max(0, options.timeoutMs));
      options.signal?.addEventListener("abort", abort, { once: true });
      process.stdout.on("data", (chunk: Buffer) => {
        if (truncated) return;
        output.push(chunk);
        const previousBytes = outputBytes;
        outputBytes += chunk.length;
        if (options.maxRecords === undefined) return;
        for (let index = 0; index < chunk.length; index += 1) {
          if (chunk[index] !== 0) continue;
          recordCount += 1;
          if (recordCount === options.maxRecords) acceptedBytes = previousBytes + index + 1;
          if (recordCount > options.maxRecords) {
            truncated = true;
            process.kill("SIGTERM");
            break;
          }
        }
      });
      process.stderr.on("data", (chunk: Buffer) => {
        if (errorBytes >= 64 * 1024) return;
        const accepted = chunk.subarray(0, 64 * 1024 - errorBytes);
        errors.push(accepted);
        errorBytes += accepted.length;
      });
      process.once("error", reject);
      process.once("close", (code) => {
        if (timeout !== undefined) clearTimeout(timeout);
        options.signal?.removeEventListener("abort", abort);
        if (options.signal?.aborted === true) reject(new FileSearchError("search_cancelled", "Search was cancelled"));
        else if (timedOut) reject(new FileSearchDeadlineError());
        else if (truncated) resolve({ output: Buffer.concat(output).subarray(0, acceptedBytes), truncated: true });
        else if (code === 0) resolve({ output: Buffer.concat(output), truncated: false });
        else reject(new NativeFileAccessError(code, Buffer.concat(errors).toString("utf8").trim() || "File access failed"));
      });
    });
  }
}

class FileSearchDeadlineError extends Error {}

class NativeFileAccessError extends Error {
  constructor(readonly exitCode: number | null, message: string) {
    super(message);
    this.name = "NativeFileAccessError";
  }
}

function assertNotCancelled(signal: AbortSignal): void {
  if (signal.aborted) throw new FileSearchError("search_cancelled", "Search was cancelled");
}

function normalizeSearchValue(value: string): string {
  return unicodeDefaultCaseFold(value);
}

function matchesSearch(entry: FileEntry, query: string): boolean {
  return normalizeSearchValue(entry.name).includes(query) || normalizeSearchValue(entry.relativePath).includes(query);
}

function compareSearchResults(left: FileEntry, right: FileEntry, query: string): number {
  const leftRank = normalizeSearchValue(left.name).startsWith(query) ? 0 : 1;
  const rightRank = normalizeSearchValue(right.name).startsWith(query) ? 0 : 1;
  if (leftRank !== rightRank) return leftRank - rightRank;
  const leftPath = normalizeSearchValue(left.relativePath);
  const rightPath = normalizeSearchValue(right.relativePath);
  return leftPath < rightPath ? -1 : leftPath > rightPath ? 1 : 0;
}

function normalizeRelativePath(value: string, allowRoot = true): string {
  if (value.startsWith("/") || value.includes("\\")) throw new Error("Path must be project-relative");
  const segments = value.split("/").filter((segment) => segment.length > 0 && segment !== ".");
  if (segments.includes("..")) throw new Error("Path traversal is not allowed");
  if (segments.some((segment) => IGNORED_NAMES.has(segment))) throw new Error("Path is ignored");
  if (!allowRoot && segments.length === 0) throw new Error("Path must identify a file");
  return segments.join("/");
}

function parseEntries(output: Buffer, parent: string): FileEntry[] {
  const entries: FileEntry[] = [];
  for (const row of output.toString("utf8").split("\0")) {
    if (row.length === 0) continue;
    const first = row.indexOf("\t");
    const second = row.indexOf("\t", first + 1);
    if (first !== 1 || second < 0) throw new Error("Invalid file helper response");
    const name = row.slice(second + 1);
    const type = row[0] === "D" ? "directory" : "file";
    const relativePath = parent.length === 0 ? name : `${parent}/${name}`;
    const extension = type === "file" ? normalizedExtension(name) : undefined;
    entries.push({
      name,
      relativePath,
      type,
      ...(type === "file" ? { size: Number.parseInt(row.slice(first + 1, second), 10) } : {}),
      ...(extension === undefined ? {} : { extension }),
      ...(type === "file" ? { isText: isText(extension), isImage: isImage(extension) } : {}),
    });
  }
  return entries;
}

function normalizedExtension(name: string): string | undefined {
  const value = extname(name).slice(1).toLowerCase();
  return value.length === 0 ? undefined : value;
}

function isText(extension: string | undefined): boolean {
  return extension !== undefined && TEXT_EXTENSIONS.has(extension);
}

function isImage(extension: string | undefined): boolean {
  return extension !== undefined && IMAGE_EXTENSIONS.has(extension);
}
