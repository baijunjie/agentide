import type { AgentAdapter } from "@agentide/agent-core";
import type { Envelope } from "@agentide/protocol";
import type { FileEntry } from "@agentide/shared-types";

export {
  ReconnectingRelayClient,
  type RelayClientOptions,
} from "./relay-client.js";
export { LocalFileService } from "./file-service.js";
export { createAgentHostServer } from "./ipc-server.js";
export { ProjectStore } from "./project-store.js";
export { SessionManager, type CreateManagedSession } from "./session-manager.js";
export { SessionStore } from "./session-store.js";

export interface FileService {
  list(projectId: string, relativePath: string): Promise<FileEntry[]>;
  readText(projectId: string, relativePath: string): Promise<string>;
  readBinary(projectId: string, relativePath: string): Promise<Uint8Array>;
  listSiblingImages(projectId: string, relativePath: string): Promise<FileEntry[]>;
}

export interface RelayClient {
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  send(envelope: Envelope): Promise<void>;
}

export interface AgentHostDependencies {
  adapters: ReadonlyMap<AgentAdapter["type"], AgentAdapter>;
  files: FileService;
  relay: RelayClient;
}

export class AgentHost {
  constructor(private readonly dependencies: AgentHostDependencies) {}

  async start(): Promise<void> {
    await this.dependencies.relay.connect();
  }

  async stop(): Promise<void> {
    await this.dependencies.relay.disconnect();
  }

  adapter(type: AgentAdapter["type"]): AgentAdapter {
    const adapter = this.dependencies.adapters.get(type);
    if (adapter === undefined) {
      throw new Error(`Agent adapter is not configured: ${type}`);
    }
    return adapter;
  }
}
