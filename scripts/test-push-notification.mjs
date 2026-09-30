import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  createAgentHostServer,
  ProjectStore,
  SessionStore,
} from "../apps/agent-host/dist/index.js";
import { InMemoryControlPlaneStore } from "../apps/server/dist/control-plane.js";
import { createRelayServer } from "../apps/server/dist/server.js";

const temporaryDirectory = await mkdtemp(join(tmpdir(), "agentide-push-integration-"));
const servers = [];

try {
  const sessionStore = new SessionStore(join(temporaryDirectory, "sessions.json"));
  const session = {
    id: "session-push",
    projectId: "project-push",
    agentType: "codex",
    title: "Review notification delivery",
    status: "running",
    createdAt: "2026-09-29T00:00:00.000Z",
    updatedAt: "2026-09-29T00:00:00.000Z",
  };
  await sessionStore.create(session);

  const hostSessions = {
    notificationPage: (afterCursor, limit) => sessionStore.notificationPage(afterCursor, limit),
    acknowledgeNotifications: (cursor) => sessionStore.acknowledgeNotifications(cursor),
  };
  const host = createAgentHostServer(
    new ProjectStore(join(temporaryDirectory, "projects.json"), ""),
    hostSessions,
    { authenticationToken: "host-secret" },
  );
  const hostBase = await listen(host);
  servers.push(host);

  const outcomes = [];
  const apnsMessages = [];
  const relay = createRelayServer({
    store: new InMemoryControlPlaneStore(),
    now: () => new Date("2026-09-29T00:00:00.000Z"),
    apnsProvider: {
      async send(message) {
        apnsMessages.push(message);
        return outcomes.shift() ?? { kind: "success" };
      },
    },
  });
  const relayBase = await listen(relay);
  servers.push(relay);

  const mac = await json(`${relayBase}/devices/register`, "POST", {
    deviceId: "mac-push",
    name: "Mac",
    kind: "mac",
  });
  const macHeaders = authenticated("mac-push", mac.token);
  const pairing = await json(`${relayBase}/pairing/sessions`, "POST", {}, macHeaders);
  const ios = await json(`${relayBase}/pairing/claim`, "POST", {
    pairingId: pairing.pairingId,
    secret: pairing.secret,
    deviceId: "ios-push",
    name: "iPhone",
  });
  const iosHeaders = authenticated("ios-push", ios.token);
  assert.equal((await request(`${relayBase}/notifications/token`, "PUT", {
    token: "c".repeat(48),
    environment: "development",
    preferences: { enabled: true, waitingEnabled: true, completionEnabled: true },
  }, iosHeaders)).status, 204);

  const devices = await json(`${relayBase}/devices`, "GET", undefined, macHeaders);
  assert.equal(devices.devices.find((device) => device.id === "ios-push")?.online, false);

  await sessionStore.record(session.id, event("approval.requested", {
    interactionId: "approval-1",
    title: "Approve",
    actions: ["approve_once", "reject"],
  }));
  const firstPage = await json(`${hostBase}/notifications/outbox?limit=50`, "GET", undefined, {
    authorization: "Bearer host-secret",
  });
  assert.equal(firstPage.items.length, 1);

  const firstResponse = await request(
    `${relayBase}/notifications/intents`,
    "POST",
    intent(firstPage.items[0]),
    macHeaders,
  );
  assert.equal(firstResponse.status, 202);
  assert.equal((await firstResponse.json()).accepted, true);
  assert.equal(apnsMessages.length, 1);
  await expectStatus(`${hostBase}/notifications/outbox/ack`, "POST", { cursor: firstPage.items[0].cursor }, {
    authorization: "Bearer host-secret",
  }, 204);
  assert.equal((await json(`${hostBase}/notifications/outbox?limit=50`, "GET", undefined, {
    authorization: "Bearer host-secret",
  })).items.length, 0);

  outcomes.push({ kind: "transient_failure" }, { kind: "success" });
  await sessionStore.record(session.id, event("session.completed", { outcome: "completed" }));
  const retryPage = await json(`${hostBase}/notifications/outbox?limit=50`, "GET", undefined, {
    authorization: "Bearer host-secret",
  });
  const retryIntent = intent(retryPage.items[0]);
  assert.equal((await request(`${relayBase}/notifications/intents`, "POST", retryIntent, macHeaders)).status, 503);
  assert.equal((await json(`${hostBase}/notifications/outbox?limit=50`, "GET", undefined, {
    authorization: "Bearer host-secret",
  })).items.length, 1);
  assert.equal((await request(`${relayBase}/notifications/intents`, "POST", retryIntent, macHeaders)).status, 202);
  await expectStatus(`${hostBase}/notifications/outbox/ack`, "POST", { cursor: retryPage.items[0].cursor }, {
    authorization: "Bearer host-secret",
  }, 204);
  assert.equal(apnsMessages.length, 3);

  console.log("Push notification Host -> Mac drain boundary -> Relay -> Mock APNs integration passed");
} finally {
  await Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve))));
  await rm(temporaryDirectory, { recursive: true, force: true, maxRetries: 3, retryDelay: 10 });
}

function event(type, extra) {
  return {
    id: crypto.randomUUID(),
    sessionId: "session-push",
    sequence: 999,
    timestamp: "2026-09-29T00:00:00.000Z",
    type,
    ...extra,
  };
}

function intent(item) {
  return {
    projectId: item.projectId,
    sessionId: item.sessionId,
    sequence: item.sequence,
    category: item.category,
    projectName: "Push Integration",
    sessionTitle: item.sessionTitle,
    createdAt: item.createdAt,
  };
}

function authenticated(deviceId, token) {
  return {
    "x-device-id": deviceId,
    authorization: `Bearer ${token}`,
  };
}

async function listen(server) {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("server did not expose a TCP address");
  return `http://127.0.0.1:${address.port}`;
}

async function json(url, method, body, headers = {}) {
  const response = await request(url, method, body, headers);
  if (!response.ok) assert.fail(`${response.status}: ${await response.text()}`);
  return response.json();
}

async function expectStatus(url, method, body, headers, status) {
  const response = await request(url, method, body, headers);
  assert.equal(response.status, status);
}

function request(url, method, body, headers = {}) {
  return fetch(url, {
    method,
    headers: {
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
