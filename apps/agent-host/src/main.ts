import { consumeCompanionConfiguration } from "./companion-config.js";
import { createAgentHostServer } from "./ipc-server.js";
import { ProjectStore } from "./project-store.js";
import { SessionManager } from "./session-manager.js";

const { port, authenticationToken, parentProcessId } = consumeCompanionConfiguration(process.env);
const projects = new ProjectStore();
const sessions = SessionManager.local(projects);
const server = createAgentHostServer(projects, sessions, { authenticationToken });
const parentWatchdog = setInterval(() => {
  try {
    process.kill(parentProcessId, 0);
  } catch {
    void shutdown();
  }
}, 1_000);
parentWatchdog.unref();

server.listen(port, "127.0.0.1", () => {
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("Agent Host did not bind a TCP port");
  }
  process.stdout.write(`${JSON.stringify({ type: "ready", port: address.port })}\n`);
});

let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  clearInterval(parentWatchdog);
  const deadline = setTimeout(() => process.exit(0), 2_000);
  deadline.unref();
  const serverClosed = new Promise<void>((resolve, reject) => {
    server.close((error) => error === undefined ? resolve() : reject(error));
  });
  server.closeAllConnections();
  try {
    await serverClosed;
    await sessions.close();
  } finally {
    clearTimeout(deadline);
  }
}
process.once("SIGINT", () => {
  void shutdown();
});
process.once("SIGTERM", () => {
  void shutdown();
});
