import { spawn } from "node:child_process";
import { extname } from "node:path";
import { fileURLToPath } from "node:url";
import type { FileEntry } from "@agentide/shared-types";
import type { ProjectStore } from "./project-store.js";

const HELPER_PATH = fileURLToPath(new URL("./native/file-access", import.meta.url));
const IGNORED_NAMES = new Set([".git", "node_modules", "DerivedData", ".build", "Pods"]);
const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "heic", "webp"]);
const TEXT_EXTENSIONS = new Set([
  "c", "cc", "cpp", "css", "h", "hpp", "html", "java", "js", "json", "jsx", "kt", "md",
  "m", "mm", "py", "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml",
  "yaml", "yml",
]);

export class LocalFileService {
  constructor(private readonly projects: ProjectStore) {}

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

  private async run(projectId: string, operation: "list" | "read", relativePath: string): Promise<Buffer> {
    const project = await this.projects.get(projectId);
    if (project === undefined) throw new Error("Project not found");
    return new Promise<Buffer>((resolve, reject) => {
      const process = spawn(HELPER_PATH, [operation, project.rootPath, relativePath], { stdio: ["ignore", "pipe", "pipe"] });
      const output: Buffer[] = [];
      const errors: Buffer[] = [];
      process.stdout.on("data", (chunk: Buffer) => output.push(chunk));
      process.stderr.on("data", (chunk: Buffer) => errors.push(chunk));
      process.once("error", reject);
      process.once("close", (code) => {
        if (code === 0) resolve(Buffer.concat(output));
        else reject(new Error(Buffer.concat(errors).toString("utf8").trim() || "File access failed"));
      });
    });
  }
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
