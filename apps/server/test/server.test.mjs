import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { createServer as createHttp2Server } from "node:http2";
import test from "node:test";
import { WebSocket } from "ws";

import {
  ControlPlane,
  InMemoryControlPlaneStore,
} from "../dist/control-plane.js";
import { createRelayServer } from "../dist/server.js";
import { Http2APNsTransport, TokenAPNsProvider } from "../dist/apns-provider.js";

test("relay starts and accepts a protocol envelope", async (context) => {
  const server = createRelayServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => server.close());

  const address = server.address();
  assert.notEqual(address, null);
  assert.equal(typeof address, "object");

  const response = await fetch(`http://127.0.0.1:${address.port}/relay`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      version: 1,
      id: "message-1",
      type: "system.ping",
      sourceDeviceId: "test-device",
      timestamp: new Date().toISOString(),
      payload: { opaque: true },
    }),
  });

  assert.equal(response.status, 202);
});

test("pairing secret is short-lived and single use", async () => {
  let now = new Date("2026-09-22T00:00:00.000Z");
  const control = new ControlPlane(
    new InMemoryControlPlaneStore(),
    () => now,
    1_000,
  );
  await control.registerMac("mac-1", "Mac");
  const pairing = await control.createPairing("mac-1", "https://relay.example");
  const claim = await control.claimPairing({
    pairingId: pairing.pairingId,
    secret: pairing.secret,
    deviceId: "ios-1",
    name: "iPhone",
  });
  assert.equal(claim.macDeviceId, "mac-1");
  await assert.rejects(() =>
    control.claimPairing({
      pairingId: pairing.pairingId,
      secret: pairing.secret,
      deviceId: "ios-2",
      name: "iPhone",
    }),
  );

  const expired = await control.createPairing("mac-1", "https://relay.example");
  now = new Date("2026-09-22T00:00:02.000Z");
  await assert.rejects(() =>
    control.claimPairing({
      pairingId: expired.pairingId,
      secret: expired.secret,
      deviceId: "ios-2",
      name: "iPhone",
    }),
  );
});

test("notification delivery claims use recoverable leases and bounded finalized retention", async () => {
  const store = new InMemoryControlPlaneStore();
  const first = await store.claimNotificationDelivery(
    "delivery-1", "2026-09-28T00:00:00.000Z", "2026-09-28T00:01:00.000Z", "2026-09-21T00:00:00.000Z",
  );
  assert.equal(first.kind, "claimed");
  assert.equal((await store.claimNotificationDelivery(
    "delivery-1", "2026-09-28T00:00:30.000Z", "2026-09-28T00:01:30.000Z", "2026-09-21T00:00:30.000Z",
  )).kind, "processing");
  const replacement = await store.claimNotificationDelivery(
    "delivery-1", "2026-09-28T00:01:01.000Z", "2026-09-28T00:02:01.000Z", "2026-09-21T00:01:01.000Z",
  );
  assert.equal(replacement.kind, "claimed");
  if (first.kind !== "claimed" || replacement.kind !== "claimed") throw new Error("expected delivery claims");
  await store.releaseNotificationDelivery("delivery-1", first.claimId);
  await store.finalizeNotificationDelivery("delivery-1", first.claimId, "2026-09-28T00:01:02.000Z");
  assert.equal((await store.claimNotificationDelivery(
    "delivery-1", "2026-09-28T00:01:30.000Z", "2026-09-28T00:02:30.000Z", "2026-09-21T00:01:30.000Z",
  )).kind, "processing");
  await store.finalizeNotificationDelivery("delivery-1", replacement.claimId, "2026-09-28T00:01:31.000Z");
  assert.equal((await store.claimNotificationDelivery(
    "delivery-1", "2026-09-28T00:02:00.000Z", "2026-09-28T00:03:00.000Z", "2026-09-21T00:02:00.000Z",
  )).kind, "finalized");
  assert.equal((await store.claimNotificationDelivery(
    "delivery-1", "2026-10-06T00:00:00.000Z", "2026-10-06T00:01:00.000Z", "2026-09-29T00:00:00.000Z",
  )).kind, "claimed");
});

test("HTTP/2 APNs transport settles connection errors and aborts without leaking session errors", async (context) => {
  const unavailable = createHttp2Server();
  await new Promise((resolve) => unavailable.listen(0, "127.0.0.1", resolve));
  const unavailablePort = unavailable.address().port;
  await new Promise((resolve) => unavailable.close(resolve));
  const transport = new Http2APNsTransport();
  await assert.rejects(transport.send(`http://127.0.0.1:${unavailablePort}`, { ":method": "POST", ":path": "/3/device/token" }, "{}", new AbortController().signal));

  const server = createHttp2Server();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => server.close(resolve)));
  const controller = new AbortController();
  const pending = transport.send(`http://127.0.0.1:${server.address().port}`, { ":method": "POST", ":path": "/3/device/token" }, "{}", controller.signal);
  controller.abort();
  await assert.rejects(pending, /aborted/);
});

test("APNs provider bounds a stalled transport and reports a retryable failure", async () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const provider = new TokenAPNsProvider({
    keyId: "KEY123",
    teamId: "TEAM123",
    topic: "dev.agentide.ios",
    privateKey: privateKey.export({ format: "pem", type: "pkcs8" }).toString(),
    requestTimeoutMilliseconds: 10,
    transport: {
      async send(_authority, _headers, _body, signal) {
        return new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true }));
      },
    },
  });
  const result = await provider.send({
    token: "token-1",
    environment: "development",
    idempotencyKey: "delivery-1",
    intent: {
      projectId: "project-1", sessionId: "session-1", sequence: 1, category: "task_completed",
      projectName: "Agent IDE", sessionTitle: "Task", createdAt: "2026-09-28T00:00:00.000Z",
    },
  });
  assert.deepEqual(result, { kind: "transient_failure" });
});

test("APNs response reasons only finalize invalid devices and unrecoverable payloads", async () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  let now = new Date("2026-09-30T00:00:00.000Z");
  const responses = [
    { status: 410, reason: "Unregistered" },
    { status: 400, reason: "PayloadTooLarge" },
    { status: 403, reason: "InvalidProviderToken" },
    { status: 400, reason: "BadTopic" },
    { status: 400, reason: "InvalidPushType" },
    { status: 400, reason: "UnexpectedFutureReason" },
    { status: 403, reason: "ExpiredProviderToken" },
    { status: 200 },
  ];
  const authorizations = [];
  const provider = new TokenAPNsProvider({
    keyId: "KEY123",
    teamId: "TEAM123",
    topic: "dev.agentide.ios",
    privateKey: privateKey.export({ format: "pem", type: "pkcs8" }).toString(),
    now: () => now,
    transport: {
      async send(_authority, headers) {
        authorizations.push(headers.authorization);
        return responses.shift();
      },
    },
  });
  const message = {
    token: "a".repeat(64), environment: "development", idempotencyKey: "delivery-1",
    intent: {
      projectId: "project-1", sessionId: "session-1", sequence: 1, category: "task_completed",
      projectName: "Agent IDE", sessionTitle: "Task", createdAt: "2026-09-28T00:00:00.000Z",
    },
  };
  for (const kind of ["invalid_token", "permanent_failure", "transient_failure", "transient_failure", "transient_failure", "transient_failure", "transient_failure", "success"]) {
    assert.equal((await provider.send(message)).kind, kind);
    now = new Date(now.getTime() + 1_000);
  }
  const expiredToken = authorizations[6]?.split(".")[1];
  const refreshedToken = authorizations[7]?.split(".")[1];
  assert.notEqual(expiredToken, refreshedToken);
});

test("an expired response cannot evict a JWT refreshed by a concurrent request", async () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  let now = new Date("2026-09-30T00:00:00.000Z");
  let releaseExpiredResponse;
  const expiredResponse = new Promise((resolve) => { releaseExpiredResponse = resolve; });
  const authorizations = [];
  let requests = 0;
  const provider = new TokenAPNsProvider({
    keyId: "KEY123",
    teamId: "TEAM123",
    topic: "dev.agentide.ios",
    privateKey: privateKey.export({ format: "pem", type: "pkcs8" }).toString(),
    now: () => now,
    transport: {
      async send(_authority, headers) {
        authorizations.push(headers.authorization);
        requests += 1;
        return requests === 1 ? expiredResponse : { status: 200 };
      },
    },
  });
  const message = {
    token: "a".repeat(48), environment: "development", idempotencyKey: "delivery-1",
    intent: {
      projectId: "project-1", sessionId: "session-1", sequence: 1, category: "task_completed",
      projectName: "Agent IDE", sessionTitle: "Task", createdAt: "2026-09-28T00:00:00.000Z",
    },
  };
  const first = provider.send(message);
  await Promise.resolve();
  now = new Date(now.getTime() + 51 * 60 * 1_000);
  assert.equal((await provider.send(message)).kind, "success");
  releaseExpiredResponse({ status: 403, reason: "ExpiredProviderToken" });
  assert.equal((await first).kind, "transient_failure");
  assert.equal((await provider.send(message)).kind, "success");
  assert.notEqual(authorizations[0], authorizations[1]);
  assert.equal(authorizations[1], authorizations[2]);
});

test("paired websocket devices receive presence and routed envelopes", async (context) => {
  const server = createRelayServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => server.close());
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;

  const registration = await post(`${base}/devices/register`, {
    deviceId: "mac-1",
    name: "Mac",
    kind: "mac",
  });
  const takeover = await fetch(`${base}/devices/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ deviceId: "mac-1", name: "Attacker", kind: "mac" }),
  });
  assert.equal(takeover.status, 409);
  const pairing = await post(
    `${base}/pairing/sessions`,
    {},
    { "x-device-id": "mac-1", authorization: `Bearer ${registration.token}` },
  );
  const claim = await post(`${base}/pairing/claim`, {
    pairingId: pairing.pairingId,
    secret: pairing.secret,
    deviceId: "ios-1",
    name: "iPhone",
  });
  const mac = await connect(
    `ws://127.0.0.1:${port}/connect?deviceId=mac-1`,
    registration.token,
  );
  const macPresence = nextMessageMatching(mac, (message) => message.type === "system.presence" && message.payload.online === true);
  const ios = await connect(
    `ws://127.0.0.1:${port}/connect?deviceId=ios-1`,
    claim.token,
  );
  context.after(() => {
    mac.close();
    ios.close();
  });

  const presence = await macPresence;
  assert.equal(presence.type, "system.presence");
  assert.equal(presence.payload.online, true);
  const envelope = {
    version: 1,
    id: "route-1",
    type: "project.list",
    sourceDeviceId: "mac-1",
    targetDeviceId: "ios-1",
    timestamp: new Date().toISOString(),
    payload: { projects: [] },
  };
  const routedEnvelope = nextMessageMatching(ios, (message) => message.id === envelope.id);
  mac.send(JSON.stringify(envelope));
  assert.deepEqual(await routedEnvelope, envelope);

  const fileError = {
    version: 1,
    id: "route-error-1",
    type: "project.listFiles.response",
    sourceDeviceId: "mac-1",
    targetDeviceId: "ios-1",
    projectId: "missing-project",
    timestamp: new Date().toISOString(),
    replyTo: "file-request-1",
    ok: false,
    payload: null,
    error: { code: "project_request_failed", message: "Project not found" },
  };
  const routedError = nextMessageMatching(ios, (message) => message.id === fileError.id);
  mac.send(JSON.stringify(fileError));
  assert.deepEqual(await routedError, fileError);

  const closed = new Promise((resolve) => ios.once("close", resolve));
  const revoke = await fetch(`${base}/devices/ios-1`, {
    method: "DELETE",
    headers: {
      "x-device-id": "mac-1",
      authorization: `Bearer ${registration.token}`,
    },
  });
  assert.equal(revoke.status, 204);
  await closed;

  const replacementPairing = await post(
    `${base}/pairing/sessions`,
    {},
    {
      "x-device-id": "mac-1",
      authorization: `Bearer ${registration.token}`,
    },
  );
  const replacementClaim = await post(`${base}/pairing/claim`, {
    pairingId: replacementPairing.pairingId,
    secret: replacementPairing.secret,
    deviceId: "ios-1",
    name: "iPhone",
  });
  const replacement = await connect(
    `ws://127.0.0.1:${port}/connect?deviceId=ios-1`,
    replacementClaim.token,
  );
  replacement.close();
});

test("notification control plane validates bindings, preferences, idempotency, and APNs outcomes", async (context) => {
  const store = new InMemoryControlPlaneStore();
  const outcomes = [];
  const sent = [];
  let blockedOutcome;
  const apnsProvider = {
    async send(message) {
      sent.push(message);
      if (blockedOutcome !== undefined) return blockedOutcome;
      return outcomes.shift() ?? { kind: "success" };
    },
  };
  const server = createRelayServer({ store, apnsProvider, now: () => new Date("2026-09-28T00:00:00.000Z") });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => server.close());
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  const registration = await post(`${base}/devices/register`, { deviceId: "mac-push", name: "Mac", kind: "mac" });
  const macHeaders = { "x-device-id": "mac-push", authorization: `Bearer ${registration.token}` };
  const pairing = await post(`${base}/pairing/sessions`, {}, macHeaders);
  const claim = await post(`${base}/pairing/claim`, {
    pairingId: pairing.pairingId, secret: pairing.secret, deviceId: "ios-push", name: "iPhone",
  });
  const iosHeaders = { "x-device-id": "ios-push", authorization: `Bearer ${claim.token}` };
  assert.equal((await request(`${base}/notifications/token`, "PUT", {
    token: "a".repeat(63), environment: "development",
    preferences: { enabled: true, waitingEnabled: true, completionEnabled: false },
  }, iosHeaders)).status, 400);
  assert.equal((await request(`${base}/notifications/token`, "PUT", {
    token: "g".repeat(64), environment: "development",
    preferences: { enabled: true, waitingEnabled: true, completionEnabled: false },
  }, iosHeaders)).status, 400);
  assert.equal((await request(`${base}/notifications/token`, "PUT", {
    token: "a".repeat(514), environment: "development",
    preferences: { enabled: true, waitingEnabled: true, completionEnabled: false },
  }, iosHeaders)).status, 400);
  assert.equal((await request(`${base}/notifications/token`, "PUT", {
    token: "c".repeat(512), environment: "development",
    preferences: { enabled: true, waitingEnabled: true, completionEnabled: false },
  }, iosHeaders)).status, 204);
  assert.equal((await request(`${base}/notifications/token`, "PUT", {
    token: "a".repeat(48), environment: "development",
    preferences: { enabled: true, waitingEnabled: true, completionEnabled: false },
  }, iosHeaders)).status, 204);
  const secondPairing = await post(`${base}/pairing/sessions`, {}, macHeaders);
  const secondClaim = await post(`${base}/pairing/claim`, {
    pairingId: secondPairing.pairingId, secret: secondPairing.secret, deviceId: "ios-push-2", name: "iPad",
  });
  const secondIOSHeaders = { "x-device-id": "ios-push-2", authorization: `Bearer ${secondClaim.token}` };
  assert.equal((await request(`${base}/notifications/token`, "PUT", {
    token: "b".repeat(64), environment: "production",
    preferences: { enabled: true, waitingEnabled: false, completionEnabled: true },
  }, secondIOSHeaders)).status, 204);

  const intent = {
    projectId: "project-1", sessionId: "session-1", sequence: 7, category: "approval_waiting",
    projectName: "Agent IDE", sessionTitle: "Fix tests", createdAt: "2026-09-28T00:00:00.000Z",
  };
  assert.equal((await request(`${base}/notifications/intents`, "POST", intent, iosHeaders)).status, 401);
  assert.equal((await request(`${base}/notifications/intents`, "POST", { ...intent, command: "secret" }, macHeaders)).status, 400);
  assert.equal((await request(`${base}/notifications/intents`, "POST", { ...intent, sequence: Number.MAX_SAFE_INTEGER + 1 }, macHeaders)).status, 400);
  assert.equal((await request(`${base}/notifications/intents`, "POST", { ...intent, projectName: "😀".repeat(201) }, macHeaders)).status, 400);
  assert.equal((await request(`${base}/notifications/intents`, "POST", intent, macHeaders)).status, 202);
  assert.equal((await request(`${base}/notifications/intents`, "POST", intent, macHeaders)).status, 202);
  assert.equal(sent.length, 1);
  assert.equal(JSON.stringify(sent[0]).includes("command"), false);

  assert.equal((await request(`${base}/notifications/intents`, "POST", {
    ...intent, sequence: 8, category: "task_completed",
  }, macHeaders)).status, 202);
  assert.equal(sent.length, 2);
  assert.equal(sent.at(-1).token, "b".repeat(64));
  assert.equal((await request(`${base}/devices/ios-push-2`, "DELETE", undefined, macHeaders)).status, 204);

  outcomes.push({ kind: "transient_failure" }, { kind: "success" });
  const transient = { ...intent, sequence: 9 };
  assert.equal((await request(`${base}/notifications/intents`, "POST", transient, macHeaders)).status, 503);
  assert.equal((await request(`${base}/notifications/intents`, "POST", transient, macHeaders)).status, 202);

  outcomes.push({ kind: "rate_limited" }, { kind: "success" });
  const limited = { ...intent, sequence: 10 };
  assert.equal((await request(`${base}/notifications/intents`, "POST", limited, macHeaders)).status, 429);
  assert.equal((await request(`${base}/notifications/intents`, "POST", limited, macHeaders)).status, 202);

  outcomes.push({ kind: "permanent_failure" });
  const permanent = { ...intent, sequence: 11 };
  assert.equal((await request(`${base}/notifications/intents`, "POST", permanent, macHeaders)).status, 202);
  const beforeDuplicate = sent.length;
  await request(`${base}/notifications/intents`, "POST", permanent, macHeaders);
  assert.equal(sent.length, beforeDuplicate);

  let releaseBlocked;
  blockedOutcome = new Promise((resolve) => { releaseBlocked = resolve; });
  const concurrent = { ...intent, sequence: 12 };
  const firstConcurrentRequest = request(`${base}/notifications/intents`, "POST", concurrent, macHeaders);
  await waitFor(() => sent.some((message) => message.intent.sequence === concurrent.sequence));
  assert.equal((await request(`${base}/notifications/intents`, "POST", concurrent, macHeaders)).status, 503);
  releaseBlocked({ kind: "transient_failure" });
  assert.equal((await firstConcurrentRequest).status, 503);
  blockedOutcome = undefined;
  assert.equal((await request(`${base}/notifications/intents`, "POST", concurrent, macHeaders)).status, 202);

  outcomes.push({ kind: "invalid_token" });
  assert.equal((await request(`${base}/notifications/intents`, "POST", { ...intent, sequence: 13 }, macHeaders)).status, 202);
  const beforeInvalidRetry = sent.length;
  await request(`${base}/notifications/intents`, "POST", { ...intent, sequence: 14 }, macHeaders);
  assert.equal(sent.length, beforeInvalidRetry);
});

async function post(url, body, headers = {}) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  if (!response.ok) assert.fail(`${response.status}: ${await response.text()}`);
  return response.json();
}

async function request(url, method, body, headers = {}) {
  return fetch(url, {
    method,
    headers: { "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail("condition was not met");
}

async function connect(url, token) {
  const socket = new WebSocket(url, {
    headers: { authorization: `Bearer ${token}` },
  });
  await new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
  return socket;
}

async function nextMessageMatching(socket, predicate) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      socket.off("message", onMessage);
      reject(new Error("timed out waiting for matching websocket message"));
    }, 2_000);
    const onMessage = (data) => {
      const message = JSON.parse(data.toString());
      if (!predicate(message)) return;
      clearTimeout(timeout);
      socket.off("message", onMessage);
      resolve(message);
    };
    socket.on("message", onMessage);
  });
}
