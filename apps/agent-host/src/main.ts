import { createAgentHostServer } from "./ipc-server.js";

const port = Number.parseInt(process.env.AGENT_HOST_PORT ?? "8788", 10);
const server = createAgentHostServer();

server.listen(port, "127.0.0.1", () => {
  console.log(`AgentIDE host listening on http://127.0.0.1:${port}`);
});

async function shutdown() {
  server.close();
}
process.once("SIGINT", () => {
  void shutdown();
});
process.once("SIGTERM", () => {
  void shutdown();
});
