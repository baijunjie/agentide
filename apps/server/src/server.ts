import {
  createServer,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import { isEnvelope } from "@agentide/protocol";
import {
  ControlPlane,
  InMemoryControlPlaneStore,
  type ControlPlaneStore,
} from "./control-plane.js";
import { DeviceRelay } from "./relay.js";

const MAX_BODY_BYTES = 1024 * 1024;
export interface RelayServerOptions {
  store?: ControlPlaneStore;
  publicUrl?: string;
  now?: () => Date;
}
export function createRelayServer(options: RelayServerOptions = {}) {
  const control = new ControlPlane(
    options.store ?? new InMemoryControlPlaneStore(),
    options.now,
  );
  const relay = new DeviceRelay(control);
  const server = createServer(async (request, response) => {
    try {
      if (request.method === "GET" && request.url === "/health")
        return send(response, 200, { status: "ok" });
      if (request.method === "POST" && request.url === "/devices/register")
        return await register(request, response, control);
      if (request.method === "POST" && request.url === "/pairing/sessions")
        return await createPairing(
          request,
          response,
          control,
          options.publicUrl,
        );
      if (request.method === "POST" && request.url === "/pairing/claim")
        return await claim(request, response, control);
      if (request.method === "GET" && request.url === "/devices")
        return await listDevices(request, response, control, relay);
      if (
        request.method === "DELETE" &&
        request.url?.startsWith("/devices/") === true
      )
        return await revoke(request, response, control, relay);
      if (request.method === "POST" && request.url === "/relay")
        return await acceptEnvelope(request, response);
      send(response, 404, { error: "not_found" });
    } catch (error) {
      const status =
        error instanceof PayloadTooLargeError
          ? 413
          : error instanceof SyntaxError
            ? 400
            : 500;
      send(response, status, {
        error:
          status === 413
            ? "payload_too_large"
            : status === 400
              ? "invalid_json"
              : "internal_error",
      });
    }
  });
  relay.attach(server);
  return server;
}
async function register(
  request: IncomingMessage,
  response: ServerResponse,
  control: ControlPlane,
) {
  const body = await readJson(request);
  if (
    !isRecord(body) ||
    !text(body.deviceId) ||
    !text(body.name) ||
    body.kind !== "mac"
  )
    return send(response, 400, { error: "invalid_device" });
  try {
    const token = await control.registerMac(body.deviceId, body.name);
    send(response, 201, { deviceId: body.deviceId, token });
  } catch {
    send(response, 409, { error: "device_exists" });
  }
}
async function createPairing(
  request: IncomingMessage,
  response: ServerResponse,
  control: ControlPlane,
  publicUrl?: string,
) {
  const device = await authenticate(request, control);
  if (device?.kind !== "mac")
    return send(response, 401, { error: "unauthorized" });
  const base =
    publicUrl ?? `http://${request.headers.host ?? "127.0.0.1:8787"}`;
  const pairing = await control.createPairing(device.id, base);
  send(response, 201, { ...pairing, qrPayload: JSON.stringify(pairing) });
}
async function claim(
  request: IncomingMessage,
  response: ServerResponse,
  control: ControlPlane,
) {
  const body = await readJson(request);
  if (
    !isRecord(body) ||
    !text(body.pairingId) ||
    !text(body.secret) ||
    !text(body.deviceId) ||
    !text(body.name)
  )
    return send(response, 400, { error: "invalid_claim" });
  try {
    send(
      response,
      201,
      await control.claimPairing({
        pairingId: body.pairingId,
        secret: body.secret,
        deviceId: body.deviceId,
        name: body.name,
      }),
    );
  } catch {
    send(response, 410, { error: "pairing_unavailable" });
  }
}
async function listDevices(
  request: IncomingMessage,
  response: ServerResponse,
  control: ControlPlane,
  relay: DeviceRelay,
) {
  const auth = await authenticate(request, control);
  if (auth === undefined) return send(response, 401, { error: "unauthorized" });
  const devices = await Promise.all(
    (await control.store.pairedDeviceIds(auth.id)).map(async (id) => {
      const device = await control.store.device(id);
      return device === undefined
        ? undefined
        : {
            id: device.id,
            name: device.name,
            kind: device.kind,
            online: relay.isOnline(id),
          };
    }),
  );
  send(response, 200, {
    devices: devices.filter((device) => device !== undefined),
  });
}
async function revoke(
  request: IncomingMessage,
  response: ServerResponse,
  control: ControlPlane,
  relay: DeviceRelay,
) {
  const auth = await authenticate(request, control);
  if (auth === undefined) return send(response, 401, { error: "unauthorized" });
  const target = decodeURIComponent(
    request.url?.slice("/devices/".length) ?? "",
  );
  const peers = await control.store.pairedDeviceIds(auth.id);
  if (target !== auth.id && (auth.kind !== "mac" || !peers.includes(target)))
    return send(response, 403, { error: "forbidden" });
  await control.store.revokeDevice(target, new Date().toISOString());
  relay.disconnectDevice(target);
  send(response, 204, undefined);
}
async function authenticate(request: IncomingMessage, control: ControlPlane) {
  const id = request.headers["x-device-id"];
  const auth = request.headers.authorization;
  return typeof id === "string" && auth?.startsWith("Bearer ") === true
    ? control.authenticate(id, auth.slice(7))
    : undefined;
}
async function acceptEnvelope(
  request: IncomingMessage,
  response: ServerResponse,
) {
  const value = await readJson(request);
  if (!isEnvelope(value))
    return send(response, 400, { error: "invalid_envelope" });
  send(response, 202, { accepted: true, id: value.id });
}
async function readJson(request: IncomingMessage) {
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    length += buffer.length;
    if (length > MAX_BODY_BYTES) throw new PayloadTooLargeError();
    chunks.push(buffer);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
}
function send(response: ServerResponse, status: number, body: unknown) {
  if (status === 204) {
    response.writeHead(status).end();
    return;
  }
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function text(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}
class PayloadTooLargeError extends Error {}
