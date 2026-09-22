import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import type { Pool } from "pg";

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
}

export class InMemoryControlPlaneStore implements ControlPlaneStore {
  private readonly devices = new Map<string, DeviceRecord>();
  private readonly sessions = new Map<string, PairingSessionRecord>();
  private readonly bindings = new Set<string>();
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
    }
  }
}

export class PostgresControlPlaneStore implements ControlPlaneStore {
  constructor(private readonly pool: Pool) {}
  async initialize() {
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('mac','ios')), token_hash TEXT NOT NULL, revoked_at TIMESTAMPTZ);
      CREATE TABLE IF NOT EXISTS pairing_sessions (id TEXT PRIMARY KEY, mac_device_id TEXT NOT NULL REFERENCES devices(id), secret_hash TEXT NOT NULL, expires_at TIMESTAMPTZ NOT NULL, claimed_at TIMESTAMPTZ);
      CREATE TABLE IF NOT EXISTS device_bindings (mac_device_id TEXT NOT NULL REFERENCES devices(id), ios_device_id TEXT NOT NULL REFERENCES devices(id), PRIMARY KEY (mac_device_id, ios_device_id));
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
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
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
