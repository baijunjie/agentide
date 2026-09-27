import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { createConnection } from "node:net";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { consumeCompanionConfiguration } from "../dist/companion-config.js";

const companionEntrypoint = fileURLToPath(new URL("../dist/main.js", import.meta.url));

test("companion announces a random authenticated endpoint and shuts down with its supervisor", async (context) => {
  const dataDirectory = await mkdtemp(join(tmpdir(), "agentide-companion-"));
  context.after(() => rm(dataDirectory, { recursive: true, force: true }));
  const token = "companion-test-token-that-is-at-least-32-characters";
  const child = spawn(process.execPath, [companionEntrypoint], {
    env: {
      ...process.env,
      AGENTIDE_DATA_DIR: dataDirectory,
      AGENT_HOST_PORT: "0",
      AGENT_HOST_TOKEN: token,
      AGENT_HOST_PARENT_PID: String(process.pid),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  context.after(() => { if (child.exitCode === null) child.kill("SIGTERM"); });

  const lines = createInterface({ input: child.stdout });
  const [line] = await once(lines, "line");
  const ready = JSON.parse(line);
  assert.equal(ready.type, "ready");
  assert.equal(Number.isInteger(ready.port), true);
  assert.equal(ready.port > 0, true);

  const base = `http://127.0.0.1:${ready.port}`;
  assert.equal((await fetch(`${base}/health`)).status, 401);
  const health = await fetch(`${base}/health`, { headers: { authorization: `Bearer ${token}` } });
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { status: "ok" });

  child.kill("SIGTERM");
  const [status, signal] = await once(child, "close");
  assert.equal(status, 0);
  assert.equal(signal, null);
});

test("companion refuses to start without a per-launch credential", async () => {
  const child = spawn(process.execPath, [companionEntrypoint], {
    env: { ...process.env, AGENT_HOST_PORT: "0", AGENT_HOST_TOKEN: "", AGENT_HOST_PARENT_PID: String(process.pid) },
    stdio: ["ignore", "ignore", "pipe"],
  });
  let errors = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { errors += chunk; });
  const [status] = await once(child, "close");
  assert.notEqual(status, 0);
  assert.match(errors, /AGENT_HOST_TOKEN/);
});

test("companion credentials are consumed before Agent subprocesses inherit the environment", () => {
  const environment = {
    AGENT_HOST_PORT: "0",
    AGENT_HOST_TOKEN: "s".repeat(32),
    AGENT_HOST_PARENT_PID: String(process.pid),
    SAFE_VALUE: "kept",
  };
  assert.deepEqual(consumeCompanionConfiguration(environment), {
    port: 0,
    authenticationToken: "s".repeat(32),
    parentProcessId: process.pid,
  });
  assert.deepEqual(environment, { SAFE_VALUE: "kept" });
});

test("companion exits when its supervisor no longer exists", async () => {
  const token = "p".repeat(32);
  const child = spawn(process.execPath, [companionEntrypoint], {
    env: {
      ...process.env,
      AGENT_HOST_PORT: "0",
      AGENT_HOST_TOKEN: token,
      AGENT_HOST_PARENT_PID: "2147483647",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const lines = createInterface({ input: child.stdout });
  const [line] = await once(lines, "line");
  const { port } = JSON.parse(line);
  const socket = createConnection({ host: "127.0.0.1", port });
  await once(socket, "connect");
  socket.write([
    "POST /projects HTTP/1.1",
    "Host: 127.0.0.1",
    `Authorization: Bearer ${token}`,
    "Content-Type: application/json",
    "Content-Length: 100",
    "",
    "{",
  ].join("\r\n"));
  const [status, signal] = await once(child, "close");
  socket.destroy();
  assert.equal(status, 0);
  assert.equal(signal, null);
});
