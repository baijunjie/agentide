import { access, mkdir, readFile, realpath, rename, stat, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import type { AgentType, Project } from "@agentide/shared-types";

export class ProjectStore {
  private projects: Project[] | undefined;
  private loading: Promise<void> | undefined;
  private mutations: Promise<void> = Promise.resolve();

  constructor(
    private readonly filePath = join(
      process.env.AGENTIDE_DATA_DIR ?? join(homedir(), "Library", "Application Support", "AgentIDE"),
      "projects.json",
    ),
    private readonly pathEnvironment = process.env.PATH ?? "",
  ) {}

  async list(): Promise<Project[]> {
    await this.load();
    return [...(this.projects ?? [])];
  }

  async get(id: string): Promise<Project | undefined> {
    return (await this.list()).find((project) => project.id === id);
  }

  async add(rootPath: string, requestedName?: string): Promise<Project> {
    return this.mutate(async () => {
      const canonicalRoot = await realpath(rootPath);
      if (!(await stat(canonicalRoot)).isDirectory()) throw new Error("Project root must be a directory");
      const projects = await this.list();
      if (projects.some((project) => project.rootPath === canonicalRoot)) {
        throw new Error("Project is already registered");
      }
      const project: Project = {
        id: crypto.randomUUID(),
        name: normalizeName(requestedName ?? basename(canonicalRoot)),
        rootPath: canonicalRoot,
        createdAt: new Date().toISOString(),
        enabledAgents: await detectAgents(this.pathEnvironment),
      };
      projects.push(project);
      await this.save(projects);
      return project;
    });
  }

  async rename(id: string, name: string): Promise<Project> {
    return this.mutate(async () => {
      const projects = await this.list();
      const index = projects.findIndex((project) => project.id === id);
      if (index < 0) throw new Error("Project not found");
      const current = projects[index];
      if (current === undefined) throw new Error("Project not found");
      const project = { ...current, name: normalizeName(name) };
      projects[index] = project;
      await this.save(projects);
      return project;
    });
  }

  async remove(id: string): Promise<void> {
    return this.mutate(async () => {
      const projects = await this.list();
      const remaining = projects.filter((project) => project.id !== id);
      if (remaining.length === projects.length) throw new Error("Project not found");
      await this.save(remaining);
    });
  }

  private async load(): Promise<void> {
    if (this.projects !== undefined) return;
    this.loading ??= this.loadOnce();
    await this.loading;
  }

  private async loadOnce(): Promise<void> {
    try {
      const value: unknown = JSON.parse(await readFile(this.filePath, "utf8"));
      if (!Array.isArray(value)) throw new Error("Project store must contain an array");
      this.projects = value as Project[];
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      this.projects = [];
    }
  }

  private async save(projects: Project[]): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.${process.pid}.${crypto.randomUUID()}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify(projects, undefined, 2)}\n`, { mode: 0o600 });
    await rename(temporaryPath, this.filePath);
    this.projects = projects;
  }

  private mutate<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.mutations.then(operation);
    this.mutations = result.then(() => undefined, () => undefined);
    return result;
  }
}

function normalizeName(value: string): string {
  const name = value.trim();
  if (name.length === 0) throw new Error("Project name must not be empty");
  return name;
}

async function detectAgents(pathEnvironment: string): Promise<AgentType[]> {
  const agents: AgentType[] = [];
  if (await executableExists("claude", pathEnvironment)) agents.push("claude");
  if (await executableExists("codex", pathEnvironment)) agents.push("codex");
  return agents;
}

async function executableExists(name: string, pathEnvironment: string): Promise<boolean> {
  for (const directory of pathEnvironment.split(":")) {
    if (directory.length === 0) continue;
    try {
      const candidate = join(directory, name);
      if (!(await stat(candidate)).isFile()) continue;
      await access(candidate, constants.X_OK);
      return true;
    } catch {
      // A PATH entry without the executable is expected.
    }
  }
  return false;
}
