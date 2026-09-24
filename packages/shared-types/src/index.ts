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
