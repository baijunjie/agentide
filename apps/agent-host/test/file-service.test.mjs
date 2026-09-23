import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { appendFile, chmod, mkdir, mkdtemp, readFile, rename, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { createAgentHostServer, LocalFileService, ProjectStore } from "../dist/index.js";

test("project registration persists metadata and detects available agents", async (context) => {
  const fixture = await createFixture(context);
  const bin = join(fixture.base, "bin");
  await mkdir(bin);
  await mkdir(join(bin, "claude"));
  await writeFile(join(bin, "codex"), "#!/bin/sh\n");
  await chmod(join(bin, "codex"), 0o755);
  const store = new ProjectStore(fixture.storePath, bin);

  const project = await store.add(fixture.root);
  assert.equal(project.name, "project");
  assert.deepEqual(project.enabledAgents, ["codex"]);
  assert.deepEqual((await new ProjectStore(fixture.storePath, "").list())[0], project);

  assert.equal((await store.rename(project.id, "Renamed")).name, "Renamed");
  await store.remove(project.id);
  assert.deepEqual(await store.list(), []);
  assert.deepEqual(JSON.parse(await readFile(fixture.storePath, "utf8")), []);
});

test("concurrent project mutations do not lose registrations", async (context) => {
  const fixture = await createFixture(context);
  const roots = await Promise.all(["one", "two", "three"].map(async (name) => {
    const root = join(fixture.base, name);
    await mkdir(root);
    return root;
  }));
  const store = new ProjectStore(fixture.storePath, "");
  const projects = await Promise.all(roots.map((root) => store.add(root)));
  assert.deepEqual((await store.list()).map((project) => project.name).sort(), ["one", "three", "two"]);
  await Promise.all([
    store.rename(projects[0].id, "ONE"),
    store.rename(projects[1].id, "TWO"),
    store.remove(projects[2].id),
  ]);
  assert.deepEqual((await store.list()).map((project) => project.name).sort(), ["ONE", "TWO"]);
});

test("first load is shared with a concurrent registration", async (context) => {
  const fixture = await createFixture(context);
  const store = new ProjectStore(fixture.storePath, "");
  const [, project] = await Promise.all([store.list(), store.add(fixture.root)]);
  assert.deepEqual((await store.list()).map((value) => value.id), [project.id]);
  assert.deepEqual(JSON.parse(await readFile(fixture.storePath, "utf8")).map((value) => value.id), [project.id]);
});

test("file service lists safe entries and exposes internal read capabilities", async (context) => {
  const fixture = await createFixture(context);
  await mkdir(join(fixture.root, "Sources"));
  await mkdir(join(fixture.root, ".git"));
  await mkdir(join(fixture.root, "node_modules"));
  await writeFile(join(fixture.root, "README.md"), "# Project\n");
  await writeFile(join(fixture.root, "photo.PNG"), Buffer.from([1, 2, 3]));
  await writeFile(join(fixture.root, "Sources", "App.swift"), "print(\"Hello\")\n");

  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(fixture.root);
  const service = new LocalFileService(store);
  const entries = await service.list(project.id, "");

  assert.deepEqual(entries.map((entry) => entry.name), ["Sources", "photo.PNG", "README.md"]);
  assert.equal(entries.find((entry) => entry.name === "README.md")?.isText, true);
  assert.equal(entries.find((entry) => entry.name === "photo.PNG")?.isImage, true);
  assert.equal(await service.readText(project.id, "Sources/App.swift"), "print(\"Hello\")\n");
  assert.deepEqual([...await service.readBinary(project.id, "photo.PNG")], [1, 2, 3]);
  assert.deepEqual((await service.listSiblingImages(project.id, "README.md")).map((entry) => entry.name), ["photo.PNG"]);
});

test("file service rejects traversal, absolute paths, and symlink escapes", async (context) => {
  const fixture = await createFixture(context);
  const outside = join(fixture.base, "outside");
  await mkdir(outside);
  await writeFile(join(outside, "secret.txt"), "secret");
  await symlink(outside, join(fixture.root, "escape"));
  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(fixture.root);
  const service = new LocalFileService(store);

  await assert.rejects(service.list(project.id, "../outside"), /traversal/);
  await assert.rejects(service.list(project.id, outside), /project-relative/);
  await assert.rejects(service.readText(project.id, "escape/secret.txt"));
  assert.deepEqual(await service.list(project.id, ""), []);
});

test("ignored paths are rejected when requested directly or below a nested directory", async (context) => {
  const fixture = await createFixture(context);
  const ignored = [".git", "node_modules", "DerivedData", ".build", "Pods"];
  for (const name of ignored) {
    await mkdir(join(fixture.root, name));
    await writeFile(join(fixture.root, name, "secret.txt"), name);
  }
  await mkdir(join(fixture.root, "Sources", "node_modules"), { recursive: true });
  await writeFile(join(fixture.root, "Sources", "node_modules", "nested.txt"), "nested");
  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(fixture.root);
  const service = new LocalFileService(store);

  assert.deepEqual((await service.list(project.id, "")).map((entry) => entry.name), ["Sources"]);
  for (const name of ignored) {
    await assert.rejects(service.list(project.id, name), /ignored/);
    await assert.rejects(service.readText(project.id, `${name}/secret.txt`), /ignored/);
  }
  await assert.rejects(service.readText(project.id, "Sources/node_modules/nested.txt"), /ignored/);
});

test("directory replacement cannot race a read outside the registered root", async (context) => {
  const fixture = await createFixture(context);
  const outside = join(fixture.base, "outside-race");
  const safe = join(fixture.root, "safe");
  const parked = join(fixture.root, "safe-parked");
  await mkdir(outside); await mkdir(safe);
  await writeFile(join(outside, "value.txt"), "outside");
  await writeFile(join(safe, "value.txt"), "inside");
  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(fixture.root);
  const service = new LocalFileService(store);

  const reads = Array.from({ length: 80 }, async () => {
    try { return await service.readText(project.id, "safe/value.txt"); }
    catch { return "rejected"; }
  });
  for (let index = 0; index < 20; index += 1) {
    await rename(safe, parked);
    await symlink(outside, safe);
    await new Promise((resolve) => setImmediate(resolve));
    await unlink(safe);
    await rename(parked, safe);
  }
  const results = await Promise.all(reads);
  assert.equal(results.includes("outside"), false);
  assert.equal(results.every((value) => value === "inside" || value === "rejected"), true);
});

test("registered root ancestors are opened without following replacement symlinks", async (context) => {
  const fixture = await createFixture(context);
  const anchor = join(fixture.base, "anchor");
  const parked = join(fixture.base, "anchor-parked");
  const root = join(anchor, "nested-project");
  const outside = join(fixture.base, "outside-parent");
  await mkdir(root, { recursive: true });
  await mkdir(join(outside, "nested-project"), { recursive: true });
  await writeFile(join(root, "value.txt"), "inside");
  await writeFile(join(outside, "nested-project", "value.txt"), "outside");
  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(root);
  const service = new LocalFileService(store);

  await rename(anchor, parked);
  await symlink(outside, anchor);
  await assert.rejects(service.readText(project.id, "value.txt"));
  await unlink(anchor);
  await rename(parked, anchor);

  const reads = Array.from({ length: 80 }, async () => {
    try { return await service.readText(project.id, "value.txt"); }
    catch { return "rejected"; }
  });
  for (let index = 0; index < 20; index += 1) {
    await rename(anchor, parked);
    await symlink(outside, anchor);
    await new Promise((resolve) => setImmediate(resolve));
    await unlink(anchor);
    await rename(parked, anchor);
  }
  const results = await Promise.all(reads);
  assert.equal(results.includes("outside"), false);
  assert.equal(results.every((value) => value === "inside" || value === "rejected"), true);
});

test("local IPC exposes project management and safe file operations", async (context) => {
  const fixture = await createFixture(context);
  await writeFile(join(fixture.root, "README.md"), "# Project\n");
  await writeFile(join(fixture.root, "cover.png"), Buffer.from([1, 2, 3]));
  await writeFile(join(fixture.root, "oversized.txt"), Buffer.alloc(700 * 1024 + 1));
  const server = createAgentHostServer(new ProjectStore(fixture.storePath, ""));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  assert.notEqual(address, null);
  assert.equal(typeof address, "object");
  const base = `http://127.0.0.1:${address.port}`;

  const created = await jsonRequest(`${base}/projects`, "POST", { rootPath: fixture.root });
  const projects = await jsonRequest(`${base}/projects`, "GET");
  assert.equal(projects.projects[0].id, created.id);
  const files = await jsonRequest(`${base}/projects/${created.id}/files/list`, "POST", { relativePath: "" });
  assert.deepEqual(files.entries.map((entry) => entry.relativePath), ["cover.png", "oversized.txt", "README.md"]);
  const text = await jsonRequest(`${base}/projects/${created.id}/files/read-text`, "POST", { relativePath: "README.md" });
  assert.equal(text.content, "# Project\n");
  const binary = await jsonRequest(`${base}/projects/${created.id}/files/read-binary`, "POST", { relativePath: "cover.png" });
  assert.equal(binary.content, Buffer.from([1, 2, 3]).toString("base64"));
  const images = await jsonRequest(`${base}/projects/${created.id}/files/list-images`, "POST", { relativePath: "cover.png" });
  assert.deepEqual(images.entries.map((entry) => entry.relativePath), ["cover.png"]);
  const oversized = await fetch(`${base}/projects/${created.id}/files/read-text`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ relativePath: "oversized.txt" }),
  });
  assert.equal(oversized.status, 400);

  const escaped = await fetch(`${base}/projects/${created.id}/files/list`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ relativePath: ".." }),
  });
  assert.equal(escaped.status, 400);
});

test("native reads enforce the byte limit when a file grows after opening", async (context) => {
  const fixture = await createFixture(context);
  const path = join(fixture.root, "growing.txt");
  await writeFile(path, Buffer.alloc(700 * 1024));
  const helper = fileURLToPath(new URL("../dist/native/file-access", import.meta.url));
  const process = spawn(helper, ["read", fixture.root, "growing.txt"], { stdio: ["ignore", "pipe", "pipe"] });
  const closed = once(process, "close");
  process.stdout.pause();
  while (process.stdout.readableLength === 0 && process.exitCode === null) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  await appendFile(path, Buffer.alloc(64 * 1024));
  let outputBytes = 0;
  process.stdout.on("data", (chunk) => { outputBytes += chunk.length; });
  process.stdout.resume();
  const [code] = await closed;
  assert.equal(code, 1);
  assert.equal(outputBytes <= 700 * 1024, true);
});

async function createFixture(context) {
  const base = await mkdtemp(join(tmpdir(), "agentide-files-"));
  context.after(() => rm(base, { recursive: true, force: true }));
  const root = join(base, "project");
  await mkdir(root);
  return { base, root, storePath: join(base, "data", "projects.json") };
}

async function jsonRequest(url, method, body) {
  const response = await fetch(url, {
    method,
    headers: body === undefined ? undefined : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) assert.fail(`${response.status}: ${await response.text()}`);
  return response.json();
}
