export type AgentType = "claude" | "codex";

export interface Project {
  id: string;
  name: string;
  rootPath: string;
  createdAt: string;
  enabledAgents: AgentType[];
}

export type SessionStatus =
  | "starting"
  | "running"
  | "idle"
  | "waiting_user"
  | "completed"
  | "failed"
  | "cancelled";

export interface Session {
  id: string;
  projectId: string;
  agentType: AgentType;
  nativeSessionId?: string;
  title: string;
  status: SessionStatus;
  createdAt: string;
  updatedAt: string;
}

export interface FileEntry {
  name: string;
  relativePath: string;
  type: "file" | "directory";
  size?: number;
  extension?: string;
  isText?: boolean;
  isImage?: boolean;
}

export interface ProjectSearchFilesRequest {
  searchId: string;
  query: string;
  limit: number;
}

export interface ProjectCancelSearchRequest {
  searchId: string;
}

export interface ProjectSearchFilesResponse {
  searchId: string;
  query: string;
  results: FileEntry[];
  hasMore: boolean;
}

export type GitChangeKind = "added" | "modified" | "deleted" | "renamed" | "untracked";

export type GitChangeArea = "staged" | "unstaged";

interface GitChangeBase {
  relativePath: string;
  area: GitChangeArea;
  isBinary: boolean;
  oldSize?: number;
  newSize?: number;
}

export interface RenamedGitChange extends GitChangeBase {
  previousRelativePath: string;
  kind: "renamed";
}

export interface NonRenamedGitChange extends GitChangeBase {
  previousRelativePath?: never;
  kind: Exclude<GitChangeKind, "renamed">;
}

export type GitChange = RenamedGitChange | NonRenamedGitChange;

export interface GitRepositoryChangesResponse {
  isGitRepository: true;
  changes: GitChange[];
}

export interface NonGitRepositoryChangesResponse {
  isGitRepository: false;
  changes: [];
}

export type ProjectChangesResponse = GitRepositoryChangesResponse | NonGitRepositoryChangesResponse;

export interface ProjectDiffRequest {
  relativePath: string;
  area: GitChangeArea;
}

export interface TextProjectDiffResponse {
  change: GitChange & { isBinary: false };
  diff?: string;
}

export interface BinaryProjectDiffResponse {
  change: GitChange & { isBinary: true };
  diff?: never;
}

export type ProjectDiffResponse = TextProjectDiffResponse | BinaryProjectDiffResponse;
