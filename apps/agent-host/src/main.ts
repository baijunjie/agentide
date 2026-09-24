import { createAgentHostServer } from "./ipc-server.js";
import { ProjectStore } from "./project-store.js";
import { SessionManager } from "./session-manager.js";

const port = Number.parseInt(process.env.AGENT_HOST_PORT ?? "8788", 10);
const projects = new ProjectStore();
const sessions = SessionManager.local(projects);
const server = createAgentHostServer(projects, sessions);

server.listen(port, "127.0.0.1", () => {
  console.log(`AgentIDE host listening on http://127.0.0.1:${port}`);
});

async function shutdown() {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => error === undefined ? resolve() : reject(error));
  });
  await sessions.close();
}
process.once("SIGINT", () => {
  void shutdown();
});
process.once("SIGTERM", () => {
  void shutdown();
});
