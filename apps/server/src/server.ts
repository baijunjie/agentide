import {
  createServer,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import { createHash } from "node:crypto";
import { isEnvelope, isProtocolTimestamp, type NotificationIntent, type NotificationPreferences, type PushEnvironment } from "@agentide/protocol";
import {
  ControlPlane,
  InMemoryControlPlaneStore,
  type ControlPlaneStore,
} from "./control-plane.js";
import { DeviceRelay } from "./relay.js";
import { type APNsProvider, UnavailableAPNsProvider } from "./apns-provider.js";

const MAX_BODY_BYTES = 1024 * 1024;
const NOTIFICATION_LEASE_MS = 60_000;
const NOTIFICATION_RETENTION_MS = 7 * 24 * 60 * 60 * 1_000;
export interface RelayServerOptions {
  store?: ControlPlaneStore;
  publicUrl?: string;
  now?: () => Date;
  apnsProvider?: APNsProvider;
}
export function createRelayServer(options: RelayServerOptions = {}) {
  const control = new ControlPlane(
    options.store ?? new InMemoryControlPlaneStore(),
    options.now,
  );
  const relay = new DeviceRelay(control);
  const apns = options.apnsProvider ?? new UnavailableAPNsProvider();
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
      if (request.method === "PUT" && request.url === "/notifications/token")
        return await registerPushToken(request, response, control);
      if (request.method === "DELETE" && request.url === "/notifications/token")
        return await removePushToken(request, response, control);
      if (request.method === "POST" && request.url === "/notifications/intents")
        return await acceptNotificationIntent(request, response, control, apns, options.now ?? (() => new Date()));
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

async function registerPushToken(
  request: IncomingMessage,
  response: ServerResponse,
  control: ControlPlane,
) {
  const auth = await authenticate(request, control);
  if (auth?.kind !== "ios") return send(response, 401, { error: "unauthorized" });
  const body = await readJson(request);
  if (!isPushTokenRegistration(body)) return send(response, 400, { error: "invalid_push_token" });
  await control.store.savePushToken({ deviceId: auth.id, ...body, updatedAt: new Date().toISOString() });
  send(response, 204, undefined);
}

async function removePushToken(
  request: IncomingMessage,
  response: ServerResponse,
  control: ControlPlane,
) {
  const auth = await authenticate(request, control);
  if (auth?.kind !== "ios") return send(response, 401, { error: "unauthorized" });
  await control.store.removePushTokens(auth.id);
  send(response, 204, undefined);
}

async function acceptNotificationIntent(
  request: IncomingMessage,
  response: ServerResponse,
  control: ControlPlane,
  apns: APNsProvider,
  now: () => Date,
) {
  const auth = await authenticate(request, control);
  if (auth?.kind !== "mac") return send(response, 401, { error: "unauthorized" });
  const body = await readJson(request);
  if (!isNotificationIntent(body)) return send(response, 400, { error: "invalid_notification_intent" });
  const tokens = (await control.store.pushTokensForMac(auth.id)).filter((token) => allows(token.preferences, body.category));
  let transientFailure = false;
  let rateLimited = false;
  let delivered = 0;
  for (const token of tokens) {
    const key = createHash("sha256").update(JSON.stringify([
      auth.id, token.deviceId, body.sessionId, body.sequence, body.category,
    ])).digest("hex");
    const claimedAt = now();
    const claim = await control.store.claimNotificationDelivery(
      key,
      claimedAt.toISOString(),
      new Date(claimedAt.getTime() + NOTIFICATION_LEASE_MS).toISOString(),
      new Date(claimedAt.getTime() - NOTIFICATION_RETENTION_MS).toISOString(),
    );
    if (claim.kind === "finalized") continue;
    if (claim.kind === "processing") {
      transientFailure = true;
      continue;
    }
    const result = await apns.send({ token: token.token, environment: token.environment, intent: body, idempotencyKey: key });
    if (result.kind === "success") {
      delivered += 1;
      await control.store.finalizeNotificationDelivery(key, claim.claimId, now().toISOString());
    } else if (result.kind === "invalid_token") {
      await control.store.invalidatePushToken(token.token, token.environment);
      await control.store.finalizeNotificationDelivery(key, claim.claimId, now().toISOString());
    } else if (result.kind === "permanent_failure") {
      await control.store.finalizeNotificationDelivery(key, claim.claimId, now().toISOString());
    }
    else if (result.kind === "transient_failure" || result.kind === "rate_limited") {
      await control.store.releaseNotificationDelivery(key, claim.claimId);
      transientFailure ||= result.kind === "transient_failure";
      rateLimited ||= result.kind === "rate_limited";
    }
  }
  if (rateLimited) return send(response, 429, { error: "apns_rate_limited" });
  if (transientFailure) return send(response, 503, { error: "apns_unavailable" });
  send(response, 202, { accepted: true, delivered });
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

function isPushTokenRegistration(value: unknown): value is {
  token: string;
  environment: PushEnvironment;
  preferences: NotificationPreferences;
} {
  if (!isRecord(value) || !hasOnlyKeys(value, ["token", "environment", "preferences"])) return false;
  return typeof value.token === "string" && /^(?:[0-9a-fA-F]{2}){1,256}$/.test(value.token) &&
    (value.environment === "development" || value.environment === "production") &&
    isNotificationPreferences(value.preferences);
}

function isNotificationPreferences(value: unknown): value is NotificationPreferences {
  return isRecord(value) && hasOnlyKeys(value, ["enabled", "waitingEnabled", "completionEnabled"]) &&
    typeof value.enabled === "boolean" && typeof value.waitingEnabled === "boolean" &&
    typeof value.completionEnabled === "boolean";
}

function isNotificationIntent(value: unknown): value is NotificationIntent {
  if (!isRecord(value) || !hasOnlyKeys(value, [
    "projectId", "sessionId", "sequence", "category", "projectName", "sessionTitle", "createdAt",
  ])) return false;
  return text(value.projectId) && text(value.sessionId) && Number.isSafeInteger(value.sequence) &&
    (value.sequence as number) >= 0 &&
    ["approval_waiting", "question_waiting", "task_completed", "task_failed"].includes(String(value.category)) &&
    text(value.projectName) && unicodeScalarCount(value.projectName) <= 200 && text(value.sessionTitle) &&
    unicodeScalarCount(value.sessionTitle) <= 200 && isProtocolTimestamp(value.createdAt);
}

function allows(preferences: NotificationPreferences, category: NotificationIntent["category"]): boolean {
  if (!preferences.enabled) return false;
  return category === "approval_waiting" || category === "question_waiting"
    ? preferences.waitingEnabled
    : preferences.completionEnabled;
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).every((key) => keys.includes(key));
}
function unicodeScalarCount(value: string): number {
  return [...value].length;
}
class PayloadTooLargeError extends Error {}
