import { createServer } from "node:http";

// TODO: Replace the health-only bootstrap with relay, file, and adapter composition across milestones 02, 03, 05, and 06.
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
