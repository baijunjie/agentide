import { spawn, type SpawnOptions } from "node:child_process";
import { fileURLToPath } from "node:url";
import { relative, resolve } from "node:path";
import type { GitChange, GitChangeArea, ProjectChangesResponse, ProjectDiffResponse } from "@agentide/shared-types";
import type { ProjectStore } from "./project-store.js";

const GIT_PATH = "/usr/bin/git";
const FILE_ACCESS_PATH = fileURLToPath(new URL("./native/file-access", import.meta.url));
const OUTPUT_LIMIT = 700 * 1024;
const TIMEOUT_MS = 10_000;
const MAX_CONCURRENT_COMMANDS = 2;

export type GitArea = GitChangeArea;
type TerminationReason = "timeout" | "output_limit";
type FileMetadata = { type: "file" | "symlink" | "other"; size?: number; isBinary?: boolean };
type RawChange = { oldMode: string; newMode: string; oldObject: string; newObject: string };

export class GitServiceError extends Error {
  constructor(readonly code: "git_not_repository" | "git_timeout" | "git_output_too_large" | "git_busy" | "git_query_failed" | "git_invalid_path", message: string) {
    super(message);
  }
}

export class LocalGitService {
  private running = 0;
  private readonly waiting: Array<() => void> = [];

  constructor(
    private readonly projects: ProjectStore,
    private readonly gitPath = GIT_PATH,
    private readonly limits = { outputBytes: OUTPUT_LIMIT, timeoutMs: TIMEOUT_MS, maxConcurrent: MAX_CONCURRENT_COMMANDS },
  ) {}

  async listChanges(projectId: string): Promise<ProjectChangesResponse> {
    const project = await this.project(projectId);
    try {
      const [status, stagedRaw, unstagedRaw, stagedNumstat, unstagedNumstat] = await Promise.all([
        this.run(project.rootPath, ["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"]),
        this.run(project.rootPath, diffArguments("staged", "--raw", "-z")),
        this.run(project.rootPath, diffArguments("unstaged", "--raw", "-z")),
        this.run(project.rootPath, diffArguments("staged", "--numstat", "-z")),
        this.run(project.rootPath, diffArguments("unstaged", "--numstat", "-z")),
      ]);
      const raw = { staged: parseRaw(stagedRaw), unstaged: parseRaw(unstagedRaw) };
      const numstat = { staged: parseNumstat(stagedNumstat), unstaged: parseNumstat(unstagedNumstat) };
      const objects = new Set<string>();
      for (const entries of [raw.staged, raw.unstaged]) {
        for (const entry of entries.values()) {
          if (isRegularMode(entry.oldMode)) objects.add(entry.oldObject);
          if (isRegularMode(entry.newMode)) objects.add(entry.newObject);
        }
      }
      const sizes = await this.objectSizes(project.rootPath, objects);
      return { isGitRepository: true, changes: await this.parseStatus(project.rootPath, status, raw, numstat, sizes) };
    } catch (error) {
      if (error instanceof GitServiceError && error.code === "git_not_repository") return { isGitRepository: false, changes: [] };
      throw error;
    }
  }

  async readDiff(projectId: string, relativePath: string, area: GitArea): Promise<ProjectDiffResponse> {
    const project = await this.project(projectId);
    const path = this.validatePath(project.rootPath, relativePath);
    const changes = (await this.listChanges(projectId)).changes;
    const change = changes.find((candidate) => candidate.relativePath === path && candidate.area === area);
    if (change === undefined) throw new GitServiceError("git_query_failed", "Git change was not found");
    if (change.isBinary) return { change: { ...change, isBinary: true } };
    if (change.kind === "untracked") {
      const content = await this.readProjectFile(project.rootPath, path);
      if (content.includes(0)) return { change: { ...change, isBinary: true } };
      const diff = untrackedDiff(path, content.toString("utf8"));
      this.assertFinalOutputSize(Buffer.byteLength(diff, "utf8"));
      return { change: { ...change, isBinary: false }, diff };
    }
    const output = await this.run(project.rootPath, [...diffArguments(area, "--patch"), "--", literalPathspec(path)]);
    const isBinary = output.includes(Buffer.from("Binary files ")) || output.includes(Buffer.from("GIT binary patch"));
    if (isBinary) return { change: { ...change, isBinary: true } };
    const diff = output.toString("utf8");
    this.assertFinalOutputSize(Buffer.byteLength(diff, "utf8"));
    return { change: { ...change, isBinary: false }, diff };
  }

  private async parseStatus(root: string, output: Buffer, raw: Record<GitArea, Map<string, RawChange>>, numstat: Record<GitArea, Map<string, boolean>>, sizes: Map<string, number>): Promise<GitChange[]> {
    const fields = output.toString("utf8").split("\0");
    const changes: GitChange[] = [];
    for (let index = 0; index < fields.length; index += 1) {
      const record = fields[index];
      if (record === undefined || record.length === 0) continue;
      if (record.length < 4 || record[2] !== " ") throw new GitServiceError("git_query_failed", "Git returned an invalid status response");
      const indexStatus = record[0] ?? " ";
      const worktreeStatus = record[1] ?? " ";
      const path = this.validatePath(root, record.slice(3));
      const renamed = isRenameStatus(indexStatus) || isRenameStatus(worktreeStatus);
      const previousRelativePath = renamed ? this.validatePath(root, fields[++index] ?? "") : undefined;
      if (indexStatus !== " " && indexStatus !== "?") changes.push(await this.change(root, path, indexStatus, "staged", previousRelativePath, raw.staged.get(path), numstat.staged.get(path), sizes));
      if (indexStatus === "?" && worktreeStatus === "?") changes.push(await this.change(root, path, "?", "unstaged", undefined, undefined, undefined, sizes));
      else if (worktreeStatus !== " ") changes.push(await this.change(root, path, worktreeStatus, "unstaged", previousRelativePath, raw.unstaged.get(path), numstat.unstaged.get(path), sizes));
    }
    return changes;
  }

  private async change(root: string, path: string, flag: string, area: GitArea, previousRelativePath: string | undefined, raw: RawChange | undefined, binary: boolean | undefined, sizes: Map<string, number>): Promise<GitChange> {
    const metadata = flag === "D" ? undefined : await this.metadata(root, path, flag === "?");
    const oldSize = raw !== undefined && isRegularMode(raw.oldMode) ? sizes.get(raw.oldObject) : undefined;
    const newSize = raw !== undefined && isRegularMode(raw.newMode)
      ? area === "staged" ? sizes.get(raw.newObject) : metadata?.size
      : flag === "?" ? metadata?.size : undefined;
    const modeIsOpaque = raw !== undefined && (
      (raw.oldMode !== "000000" && !isRegularMode(raw.oldMode)) ||
      (raw.newMode !== "000000" && !isRegularMode(raw.newMode))
    );
    const isBinary = modeIsOpaque || metadata?.type === "symlink" || binary === true || (flag === "?" && metadata?.isBinary === true);
    const base = { relativePath: path, area, isBinary, ...(oldSize === undefined ? {} : { oldSize }), ...(newSize === undefined ? {} : { newSize }) };
    if (isRenameStatus(flag)) {
      if (previousRelativePath === undefined) throw new GitServiceError("git_query_failed", "Git rename is missing its previous path");
      return { ...base, kind: "renamed", previousRelativePath };
    }
    return { ...base, kind: flag === "A" ? "added" : flag === "D" ? "deleted" : flag === "?" ? "untracked" : "modified" };
  }

  private async metadata(root: string, path: string, inspect = false): Promise<FileMetadata | undefined> {
    try {
      const [kind, size, binary] = (await this.fileAccess(inspect ? "inspect" : "stat", root, path)).toString("utf8").trim().split("\t");
      if (kind === "F") return { type: "file", size: Number(size), ...(binary === undefined ? {} : { isBinary: binary === "1" }) };
      if (kind === "L") return { type: "symlink" };
      return { type: "other" };
    } catch (error) {
      if (error instanceof GitServiceError) throw error;
      if (error instanceof FileAccessError && (error.reason === "missing" || error.reason === "symlink")) {
        return inspect ? this.metadata(root, path) : undefined;
      }
      throw new GitServiceError("git_query_failed", "Unable to inspect a project file");
    }
  }

  private async readProjectFile(root: string, path: string): Promise<Buffer> {
    let content: Buffer;
    try { content = await this.fileAccess("read", root, path); }
    catch (error) {
      if (error instanceof GitServiceError) throw error;
      if (error instanceof FileAccessError && error.reason === "too_large") throw new GitServiceError("git_output_too_large", "Git output exceeded the size limit");
      throw new GitServiceError("git_query_failed", "Unable to read an untracked file");
    }
    this.assertFinalOutputSize(content.length);
    return content;
  }

  private assertFinalOutputSize(bytes: number): void {
    if (bytes > this.limits.outputBytes) throw new GitServiceError("git_output_too_large", "Git output exceeded the size limit");
  }

  private async fileAccess(operation: "read" | "stat" | "inspect", root: string, path: string): Promise<Buffer> {
    await this.acquire();
    try {
      return await runFileAccess(operation, root, path, this.limits.timeoutMs);
    } catch (error) {
      if (error instanceof FileAccessError && error.reason === "timeout") throw new GitServiceError("git_timeout", "Git query timed out");
      throw error;
    }
    finally { this.release(); }
  }

  private async objectSizes(root: string, objects: Set<string>): Promise<Map<string, number>> {
    const names = [...objects].filter((object) => /^[0-9a-f]{40,64}$/.test(object));
    if (names.length === 0) return new Map();
    const output = await this.run(root, ["--no-optional-locks", "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"], `${names.join("\n")}\n`);
    const sizes = new Map<string, number>();
    for (const line of output.toString("utf8").trim().split("\n")) {
      const [object, type, size] = line.split(" ");
      if (object !== undefined && type === "blob" && size !== undefined && /^\d+$/.test(size)) sizes.set(object, Number(size));
    }
    return sizes;
  }

  private validatePath(root: string, value: string): string {
    if (value.length === 0 || value.startsWith("/") || value.includes("\\") || value.split("/").some((part) => part === "" || part === "." || part === "..")) throw new GitServiceError("git_invalid_path", "Git returned an invalid project-relative path");
    if (relative(root, resolve(root, value)).startsWith("..")) throw new GitServiceError("git_invalid_path", "Git returned a path outside the project");
    return value;
  }

  private async project(projectId: string) {
    const project = await this.projects.get(projectId);
    if (project === undefined) throw new Error("Project not found");
    return project;
  }

  private async run(cwd: string, args: string[], input?: string): Promise<Buffer> {
    await this.acquire();
    try {
      return await new Promise<Buffer>((resolveOutput, rejectOutput) => {
        const environment = { PATH: process.env.PATH ?? "", GIT_OPTIONAL_LOCKS: "0", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_TERMINAL_PROMPT: "0", GIT_PAGER: "cat", PAGER: "cat", GIT_EXTERNAL_DIFF: "", GIT_DIFF_OPTS: "", GIT_CONFIG_COUNT: "5", GIT_CONFIG_KEY_0: "core.pager", GIT_CONFIG_VALUE_0: "cat", GIT_CONFIG_KEY_1: "color.ui", GIT_CONFIG_VALUE_1: "false", GIT_CONFIG_KEY_2: "core.fsmonitor", GIT_CONFIG_VALUE_2: "false", GIT_CONFIG_KEY_3: "diff.external", GIT_CONFIG_VALUE_3: "", GIT_CONFIG_KEY_4: "interactive.diffFilter", GIT_CONFIG_VALUE_4: "" };
        const rooted = this.gitPath === GIT_PATH;
        const child = spawn(rooted ? FILE_ACCESS_PATH : this.gitPath, rooted ? ["git-run", cwd, ...args] : args, { cwd: rooted ? undefined : cwd, env: environment, detached: true, stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"] } as SpawnOptions);
        if (child.stdout === null || child.stderr === null) { rejectOutput(new GitServiceError("git_query_failed", "Git output streams are unavailable")); return; }
        if (input !== undefined) child.stdin?.end(input);
        const stdout: Buffer[] = []; const stderr: Buffer[] = []; let bytes = 0; let reason: TerminationReason | undefined; let settled = false;
        const settle = (result: () => void) => { if (!settled) { settled = true; clearTimeout(timer); result(); } };
        const terminate = () => { if (child.pid !== undefined) { try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); } } };
        const timer = setTimeout(() => { if (reason === undefined) reason = "timeout"; terminate(); }, this.limits.timeoutMs);
        const collect = (target: Buffer[]) => (chunk: Buffer) => { bytes += chunk.length; if (bytes > this.limits.outputBytes) { if (reason === undefined) reason = "output_limit"; terminate(); } else target.push(chunk); };
        child.stdout.on("data", collect(stdout)); child.stderr.on("data", collect(stderr));
        child.once("error", (error) => settle(() => rejectOutput(new GitServiceError("git_query_failed", error.message))));
        child.once("close", (code) => {
          if (reason !== undefined) settle(() => rejectOutput(new GitServiceError(reason === "timeout" ? "git_timeout" : "git_output_too_large", reason === "timeout" ? "Git query timed out" : "Git output exceeded the size limit")));
          else if (code !== 0) { const message = Buffer.concat(stderr).toString("utf8").trim(); settle(() => rejectOutput(new GitServiceError(message.includes("not a git repository") ? "git_not_repository" : "git_query_failed", message || "Git query failed"))); }
          else settle(() => resolveOutput(Buffer.concat(stdout)));
        });
      });
    } finally { this.release(); }
  }

  private async acquire(): Promise<void> {
    if (this.running < this.limits.maxConcurrent) { this.running += 1; return; }
    if (this.waiting.length >= 8) throw new GitServiceError("git_busy", "Git service is busy");
    await new Promise<void>((resolveWaiter) => this.waiting.push(resolveWaiter));
    this.running += 1;
  }
  private release(): void { this.running -= 1; this.waiting.shift()?.(); }
}

function diffArguments(area: GitArea, format: "--raw" | "--numstat" | "--patch", nul = ""): string[] { return ["--no-optional-locks", "diff", ...(area === "staged" ? ["--cached"] : []), format, ...(nul.length > 0 ? [nul] : []), "--abbrev=64", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames"]; }
function parseRaw(output: Buffer): Map<string, RawChange> {
  const values = output.toString("utf8").split("\0");
  const changes = new Map<string, RawChange>();
  for (let index = 0; index + 1 < values.length; index += 2) {
    const [oldMode, newMode, oldObject, newObject, status] = (values[index] ?? "").split(" ");
    const path = values[index + 1] ?? "";
    if (oldMode?.startsWith(":") === true && newMode !== undefined && oldObject !== undefined && newObject !== undefined && status !== undefined && path.length > 0) {
      changes.set(path, { oldMode: oldMode.slice(1), newMode, oldObject, newObject });
    }
  }
  return changes;
}

function parseNumstat(output: Buffer): Map<string, boolean> {
  const changes = new Map<string, boolean>();
  for (const record of output.toString("utf8").split("\0")) {
    const first = record.indexOf("\t");
    const second = first < 0 ? -1 : record.indexOf("\t", first + 1);
    if (first < 0 || second < 0) continue;
    const added = record.slice(0, first);
    const deleted = record.slice(first + 1, second);
    const path = record.slice(second + 1);
    if ((added === "-" || /^\d+$/.test(added)) && (deleted === "-" || /^\d+$/.test(deleted)) && path.length > 0) changes.set(path, added === "-" || deleted === "-");
  }
  return changes;
}
function isRegularMode(mode: string): boolean { return /^100[0-7]{3}$/.test(mode); }
function isRenameStatus(value: string): boolean { return value === "R" || value === "C"; }
function literalPathspec(path: string): string { return `:(literal)${path}`; }

class FileAccessError extends Error {
  constructor(readonly reason: "too_large" | "missing" | "symlink" | "timeout" | "failed", message: string) { super(message); }
}

async function runFileAccess(operation: "read" | "stat" | "inspect", root: string, path: string, timeoutMs: number): Promise<Buffer> {
  return new Promise((resolveOutput, rejectOutput) => {
    const child = spawn(FILE_ACCESS_PATH, [operation, root, path], { stdio: ["ignore", "pipe", "pipe"] }); const stdout: Buffer[] = []; const stderr: Buffer[] = [];
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill("SIGKILL"); }, timeoutMs);
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk)); child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk)); child.once("error", rejectOutput);
    child.once("close", (code) => {
      clearTimeout(timer); if (code === 0) { resolveOutput(Buffer.concat(stdout)); return; }
      const reason = timedOut ? "timeout" : code === 10 ? "too_large" : code === 11 ? "missing" : code === 12 ? "symlink" : "failed";
      rejectOutput(new FileAccessError(reason, Buffer.concat(stderr).toString("utf8").trim() || "File access failed"));
    });
  });
}

function untrackedDiff(path: string, content: string): string {
  const oldPath = quoteGitPath(`a/${path}`); const newPath = quoteGitPath(`b/${path}`);
  if (content.length === 0) return `diff --git ${oldPath} ${newPath}\nnew file mode 100644\n--- /dev/null\n+++ ${newPath}\n`;
  const hasFinalNewline = content.endsWith("\n"); const lines = hasFinalNewline ? content.slice(0, -1).split("\n") : content.split("\n"); const body = lines.map((line) => `+${line}`).join("\n");
  return `diff --git ${oldPath} ${newPath}\nnew file mode 100644\n--- /dev/null\n+++ ${newPath}\n@@ -0,0 +1,${lines.length} @@\n${body}${hasFinalNewline ? "\n" : "\n\\ No newline at end of file\n"}`;
}

function quoteGitPath(path: string): string {
  if (!/[\t\n\r\\"\x00-\x1f\x7f]/.test(path)) return path;
  return `"${path.replace(/\\|"|\n|\r|\t|[\x00-\x1f\x7f]/g, (value) => ({ "\\": "\\\\", "\"": "\\\"", "\n": "\\n", "\r": "\\r", "\t": "\\t" })[value] ?? `\\${value.charCodeAt(0).toString(8).padStart(3, "0")}`)}"`;
}
