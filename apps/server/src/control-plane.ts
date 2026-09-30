import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import type { Pool } from "pg";
import type { NotificationPreferences, PushEnvironment } from "@agentide/protocol";

export type DeviceKind = "mac" | "ios";
export interface DeviceRecord {
  id: string;
  name: string;
  kind: DeviceKind;
  tokenHash: string;
  revokedAt?: string;
}
export interface PairingSessionRecord {
  id: string;
  macDeviceId: string;
  secretHash: string;
  expiresAt: string;
  claimedAt?: string;
}
export interface PushTokenRecord {
  deviceId: string;
  token: string;
  environment: PushEnvironment;
  preferences: NotificationPreferences;
  updatedAt: string;
}
export type NotificationDeliveryClaim =
  | { kind: "claimed"; claimId: string }
  | { kind: "processing" }
  | { kind: "finalized" };
export interface ControlPlaneStore {
  createDevice(device: DeviceRecord): Promise<void>;
  device(deviceId: string): Promise<DeviceRecord | undefined>;
  savePairingSession(session: PairingSessionRecord): Promise<void>;
  pairingSession(pairingId: string): Promise<PairingSessionRecord | undefined>;
  claimPairing(
    pairingId: string,
    iosDevice: DeviceRecord,
    claimedAt: string,
  ): Promise<void>;
  pairedDeviceIds(deviceId: string): Promise<string[]>;
  revokeDevice(deviceId: string, revokedAt: string): Promise<void>;
  savePushToken(token: PushTokenRecord): Promise<void>;
  removePushTokens(deviceId: string): Promise<void>;
  invalidatePushToken(token: string, environment: PushEnvironment): Promise<void>;
  pushTokensForMac(macDeviceId: string): Promise<PushTokenRecord[]>;
  claimNotificationDelivery(key: string, claimedAt: string, leaseExpiresAt: string, retentionCutoff: string): Promise<NotificationDeliveryClaim>;
  finalizeNotificationDelivery(key: string, claimId: string, finalizedAt: string): Promise<void>;
  releaseNotificationDelivery(key: string, claimId: string): Promise<void>;
}

export class InMemoryControlPlaneStore implements ControlPlaneStore {
  private readonly devices = new Map<string, DeviceRecord>();
  private readonly sessions = new Map<string, PairingSessionRecord>();
  private readonly bindings = new Set<string>();
  private readonly pushTokens = new Map<string, PushTokenRecord>();
  private readonly notificationDeliveries = new Map<string, { state: "processing" | "finalized"; claimId?: string; leaseExpiresAt?: string; updatedAt: string }>();
  async createDevice(device: DeviceRecord) {
    if (this.devices.has(device.id)) throw new Error("device_exists");
    this.devices.set(device.id, { ...device });
  }
  async device(id: string) {
    const value = this.devices.get(id);
    return value === undefined ? undefined : { ...value };
  }
  async savePairingSession(session: PairingSessionRecord) {
    this.sessions.set(session.id, { ...session });
  }
  async pairingSession(id: string) {
    const value = this.sessions.get(id);
    return value === undefined ? undefined : { ...value };
  }
  async claimPairing(id: string, device: DeviceRecord, claimedAt: string) {
    const session = this.sessions.get(id);
    const existing = this.devices.get(device.id);
    if (
      session === undefined ||
      session.claimedAt !== undefined ||
      (existing !== undefined && existing.revokedAt === undefined)
    )
      throw new Error("pairing_unavailable");
    this.devices.set(device.id, { ...device });
    this.sessions.set(id, { ...session, claimedAt });
    this.bindings.add(`${session.macDeviceId}\0${device.id}`);
  }
  async pairedDeviceIds(id: string) {
    const peers: string[] = [];
    for (const key of this.bindings) {
      const [mac, ios] = key.split("\0");
      if (mac === id && ios !== undefined) peers.push(ios);
      if (ios === id && mac !== undefined) peers.push(mac);
    }
    return peers;
  }
  async revokeDevice(id: string, revokedAt: string) {
    const device = this.devices.get(id);
    if (device !== undefined) {
      this.devices.set(id, { ...device, revokedAt });
      for (const key of this.bindings) {
        const [mac, ios] = key.split("\0");
        if (mac === id || ios === id) this.bindings.delete(key);
      }
      await this.removePushTokens(id);
    }
  }
  async savePushToken(token: PushTokenRecord) {
    const existing = this.pushTokens.get(`${token.environment}\0${token.token}`);
    if (existing !== undefined && existing.deviceId !== token.deviceId) throw new Error("push_token_in_use");
    for (const [key, stored] of this.pushTokens) {
      if (stored.deviceId === token.deviceId && stored.environment === token.environment) this.pushTokens.delete(key);
    }
    this.pushTokens.set(`${token.environment}\0${token.token}`, structuredClone(token));
  }
  async removePushTokens(deviceId: string) {
    for (const [key, token] of this.pushTokens) if (token.deviceId === deviceId) this.pushTokens.delete(key);
  }
  async invalidatePushToken(token: string, environment: PushEnvironment) {
    this.pushTokens.delete(`${environment}\0${token}`);
  }
  async pushTokensForMac(macDeviceId: string) {
    const iosIds = new Set(await this.pairedDeviceIds(macDeviceId));
    return [...this.pushTokens.values()].filter((token) => iosIds.has(token.deviceId)).map((token) => structuredClone(token));
  }
  async claimNotificationDelivery(key: string, claimedAt: string, leaseExpiresAt: string, retentionCutoff: string): Promise<NotificationDeliveryClaim> {
    for (const [storedKey, delivery] of this.notificationDeliveries) {
      if (delivery.state === "finalized" && delivery.updatedAt < retentionCutoff) this.notificationDeliveries.delete(storedKey);
    }
    const existing = this.notificationDeliveries.get(key);
    if (existing?.state === "finalized") return { kind: "finalized" };
    if (existing?.state === "processing" && existing.leaseExpiresAt !== undefined && existing.leaseExpiresAt > claimedAt) {
      return { kind: "processing" };
    }
    const claimId = randomUUID();
    this.notificationDeliveries.set(key, { state: "processing", claimId, leaseExpiresAt, updatedAt: claimedAt });
    return { kind: "claimed", claimId };
  }
  async finalizeNotificationDelivery(key: string, claimId: string, finalizedAt: string) {
    const current = this.notificationDeliveries.get(key);
    if (current?.state === "processing" && current.claimId === claimId) {
      this.notificationDeliveries.set(key, { state: "finalized", updatedAt: finalizedAt });
    }
  }
  async releaseNotificationDelivery(key: string, claimId: string) {
    const current = this.notificationDeliveries.get(key);
    if (current?.state === "processing" && current.claimId === claimId) this.notificationDeliveries.delete(key);
  }
}

export class PostgresControlPlaneStore implements ControlPlaneStore {
  constructor(private readonly pool: Pool) {}
  async initialize() {
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('mac','ios')), token_hash TEXT NOT NULL, revoked_at TIMESTAMPTZ);
      CREATE TABLE IF NOT EXISTS pairing_sessions (id TEXT PRIMARY KEY, mac_device_id TEXT NOT NULL REFERENCES devices(id), secret_hash TEXT NOT NULL, expires_at TIMESTAMPTZ NOT NULL, claimed_at TIMESTAMPTZ);
      CREATE TABLE IF NOT EXISTS device_bindings (mac_device_id TEXT NOT NULL REFERENCES devices(id), ios_device_id TEXT NOT NULL REFERENCES devices(id), PRIMARY KEY (mac_device_id, ios_device_id));
      CREATE TABLE IF NOT EXISTS push_tokens (device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE, token TEXT NOT NULL, environment TEXT NOT NULL CHECK (environment IN ('development','production')), preferences JSONB NOT NULL, updated_at TIMESTAMPTZ NOT NULL, PRIMARY KEY (environment, token), UNIQUE (device_id, environment));
      CREATE TABLE IF NOT EXISTS notification_deliveries (idempotency_key TEXT PRIMARY KEY, created_at TIMESTAMPTZ NOT NULL, state TEXT NOT NULL DEFAULT 'finalized' CHECK (state IN ('processing','finalized')), claim_id UUID, lease_expires_at TIMESTAMPTZ, updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());
      ALTER TABLE notification_deliveries ADD COLUMN IF NOT EXISTS state TEXT NOT NULL DEFAULT 'finalized' CHECK (state IN ('processing','finalized'));
      ALTER TABLE notification_deliveries ADD COLUMN IF NOT EXISTS claim_id UUID;
      ALTER TABLE notification_deliveries ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ;
      ALTER TABLE notification_deliveries ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
    `);
  }
  async createDevice(device: DeviceRecord) {
    await this.pool.query(
      `INSERT INTO devices (id,name,kind,token_hash,revoked_at) VALUES ($1,$2,$3,$4,$5)`,
      [
        device.id,
        device.name,
        device.kind,
        device.tokenHash,
        device.revokedAt ?? null,
      ],
    );
  }
  async device(id: string) {
    const result = await this.pool.query<{
      id: string;
      name: string;
      kind: DeviceKind;
      token_hash: string;
      revoked_at: Date | null;
    }>("SELECT * FROM devices WHERE id=$1", [id]);
    const row = result.rows[0];
    return row === undefined
      ? undefined
      : {
          id: row.id,
          name: row.name,
          kind: row.kind,
          tokenHash: row.token_hash,
          ...(row.revoked_at === null
            ? {}
            : { revokedAt: row.revoked_at.toISOString() }),
        };
  }
  async savePairingSession(session: PairingSessionRecord) {
    await this.pool.query(
      "INSERT INTO pairing_sessions (id,mac_device_id,secret_hash,expires_at,claimed_at) VALUES ($1,$2,$3,$4,$5)",
      [
        session.id,
        session.macDeviceId,
        session.secretHash,
        session.expiresAt,
        session.claimedAt ?? null,
      ],
    );
  }
  async pairingSession(id: string) {
    const result = await this.pool.query<{
      id: string;
      mac_device_id: string;
      secret_hash: string;
      expires_at: Date;
      claimed_at: Date | null;
    }>("SELECT * FROM pairing_sessions WHERE id=$1", [id]);
    const row = result.rows[0];
    return row === undefined
      ? undefined
      : {
          id: row.id,
          macDeviceId: row.mac_device_id,
          secretHash: row.secret_hash,
          expiresAt: row.expires_at.toISOString(),
          ...(row.claimed_at === null
            ? {}
            : { claimedAt: row.claimed_at.toISOString() }),
        };
  }
  async claimPairing(id: string, device: DeviceRecord, claimedAt: string) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await client.query<{ mac_device_id: string }>(
        "UPDATE pairing_sessions SET claimed_at=$2 WHERE id=$1 AND claimed_at IS NULL AND expires_at>$2 RETURNING mac_device_id",
        [id, claimedAt],
      );
      const mac = result.rows[0]?.mac_device_id;
      if (mac === undefined) throw new Error("pairing_unavailable");
      const deviceResult = await client.query(
        `INSERT INTO devices (id,name,kind,token_hash) VALUES ($1,$2,$3,$4)
         ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name, token_hash=EXCLUDED.token_hash, revoked_at=NULL
         WHERE devices.kind='ios' AND devices.revoked_at IS NOT NULL
         RETURNING id`,
        [device.id, device.name, device.kind, device.tokenHash],
      );
      if (deviceResult.rowCount !== 1) throw new Error("pairing_unavailable");
      await client.query(
        "INSERT INTO device_bindings (mac_device_id,ios_device_id) VALUES ($1,$2) ON CONFLICT DO NOTHING",
        [mac, device.id],
      );
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }
  async pairedDeviceIds(id: string) {
    const result = await this.pool.query<{ peer_id: string }>(
      "SELECT ios_device_id peer_id FROM device_bindings WHERE mac_device_id=$1 UNION SELECT mac_device_id peer_id FROM device_bindings WHERE ios_device_id=$1",
      [id],
    );
    return result.rows.map((row) => row.peer_id);
  }
  async revokeDevice(id: string, revokedAt: string) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("UPDATE devices SET revoked_at=$2 WHERE id=$1", [
        id,
        revokedAt,
      ]);
      await client.query(
        "DELETE FROM device_bindings WHERE mac_device_id=$1 OR ios_device_id=$1",
        [id],
      );
      await client.query("DELETE FROM push_tokens WHERE device_id=$1", [id]);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }
  async savePushToken(token: PushTokenRecord) {
    await this.pool.query(
      `INSERT INTO push_tokens (device_id,token,environment,preferences,updated_at) VALUES ($1,$2,$3,$4,$5)
       ON CONFLICT (device_id,environment) DO UPDATE SET token=EXCLUDED.token, preferences=EXCLUDED.preferences, updated_at=EXCLUDED.updated_at`,
      [token.deviceId, token.token, token.environment, token.preferences, token.updatedAt],
    );
  }
  async removePushTokens(deviceId: string) {
    await this.pool.query("DELETE FROM push_tokens WHERE device_id=$1", [deviceId]);
  }
  async invalidatePushToken(token: string, environment: PushEnvironment) {
    await this.pool.query("DELETE FROM push_tokens WHERE token=$1 AND environment=$2", [token, environment]);
  }
  async pushTokensForMac(macDeviceId: string) {
    const result = await this.pool.query<{
      device_id: string;
      token: string;
      environment: PushEnvironment;
      preferences: NotificationPreferences;
      updated_at: Date;
    }>(
      `SELECT p.device_id,p.token,p.environment,p.preferences,p.updated_at
       FROM push_tokens p JOIN device_bindings b ON b.ios_device_id=p.device_id
       JOIN devices d ON d.id=p.device_id
       WHERE b.mac_device_id=$1 AND d.revoked_at IS NULL`,
      [macDeviceId],
    );
    return result.rows.map((row) => ({
      deviceId: row.device_id,
      token: row.token,
      environment: row.environment,
      preferences: row.preferences,
      updatedAt: row.updated_at.toISOString(),
    }));
  }
  async claimNotificationDelivery(key: string, claimedAt: string, leaseExpiresAt: string, retentionCutoff: string): Promise<NotificationDeliveryClaim> {
    await this.pool.query(
      "DELETE FROM notification_deliveries WHERE state='finalized' AND updated_at<$1",
      [retentionCutoff],
    );
    const claimId = randomUUID();
    const result = await this.pool.query<{ state: "processing" | "finalized"; claim_id: string | null }>(
      `INSERT INTO notification_deliveries (idempotency_key,created_at,state,claim_id,lease_expires_at,updated_at)
       VALUES ($1,$2,'processing',$3,$4,$2)
       ON CONFLICT (idempotency_key) DO UPDATE
       SET state='processing',claim_id=EXCLUDED.claim_id,lease_expires_at=EXCLUDED.lease_expires_at,updated_at=EXCLUDED.updated_at
       WHERE notification_deliveries.state='processing' AND notification_deliveries.lease_expires_at<=EXCLUDED.updated_at
       RETURNING state,claim_id`,
      [key, claimedAt, claimId, leaseExpiresAt],
    );
    if (result.rowCount === 1) return { kind: "claimed", claimId: result.rows[0]?.claim_id ?? claimId };
    const existing = await this.pool.query<{ state: "processing" | "finalized" }>(
      "SELECT state FROM notification_deliveries WHERE idempotency_key=$1",
      [key],
    );
    return { kind: existing.rows[0]?.state ?? "processing" };
  }
  async finalizeNotificationDelivery(key: string, claimId: string, finalizedAt: string) {
    await this.pool.query(
      "UPDATE notification_deliveries SET state='finalized',claim_id=NULL,lease_expires_at=NULL,updated_at=$3 WHERE idempotency_key=$1 AND state='processing' AND claim_id=$2",
      [key, claimId, finalizedAt],
    );
  }
  async releaseNotificationDelivery(key: string, claimId: string) {
    await this.pool.query("DELETE FROM notification_deliveries WHERE idempotency_key=$1 AND state='processing' AND claim_id=$2", [key, claimId]);
  }
}

export class ControlPlane {
  constructor(
    readonly store: ControlPlaneStore,
    private readonly now: () => Date = () => new Date(),
    private readonly lifetimeMs = 300_000,
  ) {}
  async registerMac(id: string, name: string) {
    const token = randomToken();
    await this.store.createDevice({
      id,
      name,
      kind: "mac",
      tokenHash: hash(token),
    });
    return token;
  }
  async authenticate(id: string, token: string) {
    const device = await this.store.device(id);
    return device !== undefined &&
      device.revokedAt === undefined &&
      matches(token, device.tokenHash)
      ? device
      : undefined;
  }
  async createPairing(deviceId: string, server: string) {
    const secret = randomToken();
    const pairingId = randomUUID();
    const expiresAt = new Date(
      this.now().getTime() + this.lifetimeMs,
    ).toISOString();
    await this.store.savePairingSession({
      id: pairingId,
      macDeviceId: deviceId,
      secretHash: hash(secret),
      expiresAt,
    });
    return { version: 1 as const, server, pairingId, secret, expiresAt };
  }
  async claimPairing(input: {
    pairingId: string;
    secret: string;
    deviceId: string;
    name: string;
  }) {
    const session = await this.store.pairingSession(input.pairingId);
    const now = this.now().toISOString();
    if (
      session === undefined ||
      session.claimedAt !== undefined ||
      session.expiresAt <= now ||
      !matches(input.secret, session.secretHash)
    )
      throw new Error("pairing_unavailable");
    const token = randomToken();
    await this.store.claimPairing(
      input.pairingId,
      {
        id: input.deviceId,
        name: input.name,
        kind: "ios",
        tokenHash: hash(token),
      },
      now,
    );
    return { token, macDeviceId: session.macDeviceId };
  }
}
function randomToken() {
  return randomBytes(32).toString("base64url");
}
function hash(value: string) {
  return createHash("sha256").update(value).digest("hex");
}
function matches(value: string, expected: string) {
  const a = Buffer.from(hash(value));
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}
