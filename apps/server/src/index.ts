import { Pool } from "pg";
import { PostgresControlPlaneStore } from "./control-plane.js";
import { createRelayServer } from "./server.js";

const databaseUrl = process.env.DATABASE_URL;
if (databaseUrl === undefined) throw new Error("DATABASE_URL is required");
const publicUrl = process.env.PUBLIC_URL;
if (publicUrl === undefined) throw new Error("PUBLIC_URL is required");
if (
  new URL(publicUrl).protocol !== "https:" &&
  process.env.ALLOW_INSECURE_HTTP !== "1"
)
  throw new Error("PUBLIC_URL must use HTTPS");
const pool = new Pool({ connectionString: databaseUrl });
const store = new PostgresControlPlaneStore(pool);
await store.initialize();
const port = Number.parseInt(process.env.PORT ?? "8787", 10);
const server = createRelayServer({ store, publicUrl });
server.listen(port, "127.0.0.1", () =>
  console.log(`AgentIDE relay listening on http://127.0.0.1:${port}`),
);
async function shutdown() {
  server.close();
  await pool.end();
}
process.once("SIGINT", () => {
  void shutdown();
});
process.once("SIGTERM", () => {
  void shutdown();
});
