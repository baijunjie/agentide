import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { appendFile, chmod, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { createAgentHostServer, LocalFileService, LocalGitService, ProjectStore } from "../dist/index.js";

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
  assert.deepEqual(project.enabledAgents, ["claude", "codex"]);
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

test("existing projects gain the bundled Claude SDK capability", async (context) => {
  const fixture = await createFixture(context);
  await mkdir(join(fixture.base, "data"), { recursive: true });
  await writeFile(fixture.storePath, JSON.stringify([{
    id: "project-existing",
    name: "Existing",
    rootPath: fixture.root,
    createdAt: "2026-09-24T00:00:00.000Z",
    enabledAgents: [],
  }]));
  const [project] = await new ProjectStore(fixture.storePath, "").list();
  assert.deepEqual(project.enabledAgents, ["claude"]);
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

test("git service reports mixed changes and returns only safe unified diffs", async (context) => {
  const fixture = await createFixture(context);
  await git(fixture.root, ["init"]);
  await git(fixture.root, ["config", "user.email", "test@example.com"]);
  await git(fixture.root, ["config", "user.name", "Test"]);
  await writeFile(join(fixture.root, "tracked.txt"), "before\n");
  await git(fixture.root, ["add", "tracked.txt"]);
  await git(fixture.root, ["commit", "-m", "initial"]);
  await writeFile(join(fixture.root, "tracked.txt"), "after\n");
  await writeFile(join(fixture.root, "new.txt"), "new\n");
  await writeFile(join(fixture.root, "binary.bin"), Buffer.from([0, 1, 2]));
  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(fixture.root);
  const service = new LocalGitService(store);

  const changes = await service.listChanges(project.id);
  assert.equal(changes.isGitRepository, true);
  assert.deepEqual(changes.changes.map((change) => [change.relativePath, change.kind, change.area]).sort((left, right) => left[0].localeCompare(right[0])), [
    ["binary.bin", "untracked", "unstaged"],
    ["new.txt", "untracked", "unstaged"],
    ["tracked.txt", "modified", "unstaged"],
  ]);
  assert.equal(changes.changes.find((change) => change.relativePath === "binary.bin")?.isBinary, true);
  assert.match((await service.readDiff(project.id, "new.txt", "unstaged")).diff ?? "", /\+new/);
  assert.equal((await service.readDiff(project.id, "binary.bin", "unstaged")).diff, undefined);
  assert.match((await service.readDiff(project.id, "tracked.txt", "unstaged")).diff ?? "", /-before/);
});

test("git service preserves staged and unstaged metadata without expanding opaque entries", async (context) => {
  const fixture = await createFixture(context);
  await git(fixture.root, ["init"]);
  await git(fixture.root, ["config", "user.email", "test@example.com"]);
  await git(fixture.root, ["config", "user.name", "Test"]);
  await writeFile(join(fixture.root, "same.txt"), "old\n");
  await writeFile(join(fixture.root, "deleted.bin"), Buffer.from([0, 1]));
  await writeFile(join(fixture.root, "link"), "target");
  await git(fixture.root, ["add", "."]);
  await git(fixture.root, ["commit", "-m", "initial"]);
  await writeFile(join(fixture.root, "same.txt"), "staged\n");
  await git(fixture.root, ["add", "same.txt"]);
  await writeFile(join(fixture.root, "same.txt"), "unstaged\n");
  await git(fixture.root, ["rm", "deleted.bin"]);
  await unlink(join(fixture.root, "link"));
  await symlink("target", join(fixture.root, "link"));
  await git(fixture.root, ["add", "link"]);
  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(fixture.root);
  const changes = await new LocalGitService(store).listChanges(project.id);
  const staged = changes.changes.find((change) => change.relativePath === "same.txt" && change.area === "staged");
  const unstaged = changes.changes.find((change) => change.relativePath === "same.txt" && change.area === "unstaged");
  const deleted = changes.changes.find((change) => change.relativePath === "deleted.bin");
  const link = changes.changes.find((change) => change.relativePath === "link");
  assert.deepEqual([staged?.oldSize, staged?.newSize], [4, 7]);
  assert.deepEqual([unstaged?.oldSize, unstaged?.newSize], [7, 9]);
  assert.equal(deleted?.isBinary, true);
  assert.deepEqual([deleted?.oldSize, deleted?.newSize], [2, undefined]);
  assert.equal(link?.isBinary, true);
  assert.equal(link?.newSize, undefined);
});

test("git service retains rename source paths in the staged partition", async (context) => {
  const fixture = await createFixture(context);
  await git(fixture.root, ["init"]); await git(fixture.root, ["config", "user.email", "test@example.com"]); await git(fixture.root, ["config", "user.name", "Test"]);
  await writeFile(join(fixture.root, "before.txt"), "same content\n"); await git(fixture.root, ["add", "."]); await git(fixture.root, ["commit", "-m", "initial"]);
  await git(fixture.root, ["mv", "before.txt", "after.txt"]);
  const project = await new ProjectStore(fixture.storePath, "").add(fixture.root);
  const change = (await new LocalGitService(new ProjectStore(fixture.storePath, "")).listChanges(project.id)).changes.find((value) => value.area === "staged");
  assert.deepEqual(change && [change.kind, change.relativePath, change.previousRelativePath], ["renamed", "after.txt", "before.txt"]);
});

test("git diffs use literal pathspecs and secure untracked reads", async (context) => {
  const fixture = await createFixture(context);
  await git(fixture.root, ["init"]);
  await git(fixture.root, ["config", "user.email", "test@example.com"]);
  await git(fixture.root, ["config", "user.name", "Test"]);
  await writeFile(join(fixture.root, "literal*.txt"), "before\n");
  await writeFile(join(fixture.root, "literal?.txt"), "before\n");
  await git(fixture.root, ["add", "."]);
  await git(fixture.root, ["commit", "-m", "initial"]);
  await writeFile(join(fixture.root, "literal*.txt"), "after star\n");
  await writeFile(join(fixture.root, "literal?.txt"), "after question\n");
  await writeFile(join(fixture.root, "empty.txt"), "");
  await writeFile(join(fixture.root, "no-newline.txt"), "tail");
  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(fixture.root);
  const service = new LocalGitService(store);
  assert.match((await service.readDiff(project.id, "literal*.txt", "unstaged")).diff ?? "", /after star/);
  assert.doesNotMatch((await service.readDiff(project.id, "literal*.txt", "unstaged")).diff ?? "", /after question/);
  assert.match((await service.readDiff(project.id, "no-newline.txt", "unstaged")).diff ?? "", /\\ No newline at end of file/);
  assert.doesNotMatch((await service.readDiff(project.id, "empty.txt", "unstaged")).diff ?? "", /@@/);
  await unlink(join(fixture.root, "empty.txt"));
  await symlink(join(fixture.base, "outside"), join(fixture.root, "empty.txt"));
  await writeFile(join(fixture.base, "outside"), "secret");
  assert.equal((await service.readDiff(project.id, "empty.txt", "unstaged")).diff, undefined);
});

test("git runner rejects a registered root whose ancestor becomes a symlink", async (context) => {
  const fixture = await createFixture(context);
  const anchor = join(fixture.base, "anchor");
  const parked = join(fixture.base, "anchor-parked");
  const root = join(anchor, "project");
  const outside = join(fixture.base, "outside");
  await mkdir(root, { recursive: true });
  await mkdir(join(outside, "project"), { recursive: true });
  await git(root, ["init"]); await git(root, ["config", "user.email", "test@example.com"]); await git(root, ["config", "user.name", "Test"]);
  await writeFile(join(root, "inside.txt"), "inside\n"); await git(root, ["add", "."]); await git(root, ["commit", "-m", "initial"]);
  await git(join(outside, "project"), ["init"]);
  const project = await new ProjectStore(fixture.storePath, "").add(root);
  await rename(anchor, parked); await symlink(outside, anchor);
  await assert.rejects(new LocalGitService(new ProjectStore(fixture.storePath, "")).listChanges(project.id));
});

test("git service reports oversized untracked text and preserves the first termination reason", async (context) => {
  const fixture = await createFixture(context);
  await git(fixture.root, ["init"]);
  await writeFile(join(fixture.root, "large.txt"), Buffer.alloc(32, 0x61));
  const store = new ProjectStore(fixture.storePath, ""); const project = await store.add(fixture.root);
  const limited = new LocalGitService(store, "/usr/bin/git", { outputBytes: 16, timeoutMs: 1_000, maxConcurrent: 1 });
  assert.equal((await limited.listChanges(project.id)).changes[0]?.isBinary, false);
  await assert.rejects(limited.readDiff(project.id, "large.txt", "unstaged"), (error) => error.code === "git_output_too_large");
  const slow = join(fixture.base, "slow-git.sh");
  await writeFile(slow, "#!/bin/sh\nsleep 1\nyes x | head -c 1024\n"); await chmod(slow, 0o755);
  const first = new LocalGitService(store, slow, { outputBytes: 16, timeoutMs: 5, maxConcurrent: 1 });
  await assert.rejects(first.listChanges(project.id), (error) => error.code === "git_timeout");
});

test("git service bounds queued work with a stable busy error", async (context) => {
  const fixture = await createFixture(context); const store = new ProjectStore(fixture.storePath, ""); const project = await store.add(fixture.root);
  const slow = join(fixture.base, "slow-git.sh"); await writeFile(slow, "#!/bin/sh\nsleep 1\n"); await chmod(slow, 0o755);
  const service = new LocalGitService(store, slow, { outputBytes: 128, timeoutMs: 2_000, maxConcurrent: 1 });
  const results = await Promise.allSettled(Array.from({ length: 12 }, () => service.listChanges(project.id)));
  assert.equal(results.some((result) => result.status === "rejected" && result.reason.code === "git_busy"), true);
});

test("git service does not run repository-configured helpers", async (context) => {
  const fixture = await createFixture(context);
  await git(fixture.root, ["init"]);
  await git(fixture.root, ["config", "user.email", "test@example.com"]);
  await git(fixture.root, ["config", "user.name", "Test"]);
  await writeFile(join(fixture.root, "tracked.txt"), "before\n");
  await git(fixture.root, ["add", "tracked.txt"]);
  await git(fixture.root, ["commit", "-m", "initial"]);
  await writeFile(join(fixture.root, "tracked.txt"), "after\n");
  const marker = join(fixture.base, "executed");
  const helper = join(fixture.base, "helper.sh");
  await writeFile(helper, `#!/bin/sh\ntouch '${marker}'\n`);
  await chmod(helper, 0o755);
  await git(fixture.root, ["config", "core.fsmonitor", helper]);
  await git(fixture.root, ["config", "diff.external", helper]);
  await git(fixture.root, ["config", "diff.evil.textconv", helper]);
  await writeFile(join(fixture.root, ".gitattributes"), "tracked.txt diff=evil\n");
  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(fixture.root);
  const service = new LocalGitService(store);
  const gitStateBefore = await directoryDigest(join(fixture.root, ".git"));

  await service.listChanges(project.id);
  await service.readDiff(project.id, "tracked.txt", "unstaged");
  await assert.rejects(readFile(marker));
  assert.equal(await directoryDigest(join(fixture.root, ".git")), gitStateBefore);
});

test("git service reports fixed-runner limits and rejects untrusted paths", async (context) => {
  const fixture = await createFixture(context);
  const store = new ProjectStore(fixture.storePath, "");
  const project = await store.add(fixture.root);
  const slowHelper = join(fixture.base, "slow-git.sh");
  const floodHelper = join(fixture.base, "flood-git.sh");
  await writeFile(slowHelper, "#!/bin/sh\nsleep 1\n");
  await writeFile(floodHelper, "#!/bin/sh\nyes x | head -c 1024\n");
  await chmod(slowHelper, 0o755);
  await chmod(floodHelper, 0o755);
  const timeout = new LocalGitService(store, slowHelper, { outputBytes: 128, timeoutMs: 5, maxConcurrent: 1 });
  await assert.rejects(timeout.listChanges(project.id), (error) => error.code === "git_timeout");
  const output = new LocalGitService(store, floodHelper, { outputBytes: 16, timeoutMs: 1_000, maxConcurrent: 1 });
  await assert.rejects(output.listChanges(project.id), (error) => error.code === "git_output_too_large");

  const service = new LocalGitService(store);
  await assert.rejects(service.readDiff(project.id, "../outside;touch", "unstaged"), (error) => error.code === "git_invalid_path");
});

test("local IPC requires its per-launch bearer token when configured", async (context) => {
  const fixture = await createFixture(context);
  const token = "a".repeat(32);
  const server = createAgentHostServer(new ProjectStore(fixture.storePath, ""), undefined, { authenticationToken: token });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  const base = `http://127.0.0.1:${address.port}`;

  assert.equal((await fetch(`${base}/health`)).status, 401);
  assert.equal((await fetch(`${base}/health`, { headers: { authorization: "Bearer wrong" } })).status, 401);
  const authorized = await fetch(`${base}/health`, { headers: { authorization: `Bearer ${token}` } });
  assert.equal(authorized.status, 200);
  assert.deepEqual(await authorized.json(), { status: "ok" });
});

test("native reads enforce the byte limit when a file grows after opening", async (context) => {
  const fixture = await createFixture(context);
  const path = join(fixture.root, "growing.txt");
  await writeFile(path, Buffer.alloc(699 * 1024));
  const helper = fileURLToPath(new URL("../dist/native/file-access", import.meta.url));
  const process = spawn(helper, ["read", await realpath(fixture.root), "growing.txt"], { stdio: ["ignore", "pipe", "pipe"] });
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
  assert.equal(code, 10);
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

async function git(cwd, args) {
  await new Promise((resolve, reject) => {
    const child = spawn("/usr/bin/git", args, { cwd, stdio: "ignore" });
    child.once("error", reject);
    child.once("close", (code) => code === 0 ? resolve() : reject(new Error(`git exited with ${code}`)));
  });
}

async function directoryDigest(path) {
  const digest = createHash("sha256");
  async function visit(relativePath) {
    const entries = await readdir(join(path, relativePath), { withFileTypes: true });
    for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
      const child = join(relativePath, entry.name);
      digest.update(child);
      if (entry.isDirectory()) await visit(child);
      else digest.update(await readFile(join(path, child)));
    }
  }
  await visit("");
  return digest.digest("hex");
}
