import assert from "node:assert/strict";
import test from "node:test";
import { WebSocket } from "ws";

import {
  ControlPlane,
  InMemoryControlPlaneStore,
} from "../dist/control-plane.js";
import { createRelayServer } from "../dist/server.js";

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
  const ios = await connect(
    `ws://127.0.0.1:${port}/connect?deviceId=ios-1`,
    claim.token,
  );
  context.after(() => {
    mac.close();
    ios.close();
  });

  const presence = await nextMessage(mac);
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
  mac.send(JSON.stringify(envelope));
  assert.deepEqual(await nextMessage(ios), envelope);

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
  mac.send(JSON.stringify(fileError));
  assert.deepEqual(await nextMessage(ios), fileError);

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

async function post(url, body, headers = {}) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  if (!response.ok) assert.fail(`${response.status}: ${await response.text()}`);
  return response.json();
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

async function nextMessage(socket) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("timed out waiting for websocket message")),
      2_000,
    );
    socket.once("message", (data) => {
      clearTimeout(timeout);
      resolve(JSON.parse(data.toString()));
    });
  });
}
