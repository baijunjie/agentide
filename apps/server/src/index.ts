import { createRelayServer } from "./server.js";

const port = Number.parseInt(process.env.PORT ?? "8787", 10);
const server = createRelayServer();

server.listen(port, "127.0.0.1", () => {
  console.log(`AgentIDE relay listening on http://127.0.0.1:${port}`);
});
