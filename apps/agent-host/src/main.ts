import { createServer } from "node:http";

// TODO: Compose the Relay client through Mac App IPC in milestone 03, then add file and adapter implementations in milestones 03, 05, and 06.
const port = Number.parseInt(process.env.AGENT_HOST_PORT ?? "8788", 10);
const server = createServer((request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ status: "ok" }));
    return;
  }

  response.writeHead(404).end();
});

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
