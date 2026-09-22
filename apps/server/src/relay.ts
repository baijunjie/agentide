import type { IncomingMessage, Server as HttpServer } from "node:http";
import { isEnvelope, type Envelope } from "@agentide/protocol";
import { WebSocket, WebSocketServer } from "ws";
import type { ControlPlane } from "./control-plane.js";

interface BufferedMessage {
  expiresAt: number;
  data: string;
}
export class DeviceRelay {
  private readonly sockets = new Map<string, Set<WebSocket>>();
  private readonly alive = new WeakMap<WebSocket, boolean>();
  private readonly buffers = new Map<string, BufferedMessage[]>();
  private readonly webSockets = new WebSocketServer({
    noServer: true,
    maxPayload: 1024 * 1024,
  });
  private heartbeat?: NodeJS.Timeout;
  constructor(
    private readonly control: ControlPlane,
    private readonly now: () => number = Date.now,
    private readonly ttlMs = 30_000,
  ) {}
  attach(server: HttpServer) {
    server.on("upgrade", (request, socket, head) => {
      void this.upgrade(request, socket, head);
    });
    this.heartbeat = setInterval(() => this.pingConnections(), 15_000);
    server.on("close", () => {
      if (this.heartbeat !== undefined) clearInterval(this.heartbeat);
      this.webSockets.close();
    });
  }
  isOnline(id: string) {
    return [...(this.sockets.get(id) ?? [])].some(
      (socket) => socket.readyState === WebSocket.OPEN,
    );
  }
  disconnectDevice(id: string) {
    for (const socket of this.sockets.get(id) ?? [])
      socket.close(4003, "token revoked");
  }
  private async upgrade(
    request: IncomingMessage,
    socket: import("node:stream").Duplex,
    head: Buffer,
  ) {
    const url = new URL(
      request.url ?? "/",
      `http://${request.headers.host ?? "localhost"}`,
    );
    const id = url.searchParams.get("deviceId");
    const auth = request.headers.authorization;
    if (
      url.pathname !== "/connect" ||
      id === null ||
      auth?.startsWith("Bearer ") !== true ||
      (await this.control.authenticate(id, auth.slice(7))) === undefined
    ) {
      socket.destroy();
      return;
    }
    this.webSockets.handleUpgrade(request, socket, head, (ws) =>
      this.connected(id, ws),
    );
  }
  private connected(id: string, socket: WebSocket) {
    const connections = this.sockets.get(id) ?? new Set<WebSocket>();
    connections.add(socket);
    this.sockets.set(id, connections);
    this.alive.set(socket, true);
    this.flush(id, socket);
    socket.on("pong", () => this.alive.set(socket, true));
    socket.on("message", (data) => {
      void this.route(id, data.toString());
    });
    socket.on("close", () => {
      const current = this.sockets.get(id);
      if (current === undefined) return;
      current.delete(socket);
      if (current.size === 0) {
        this.sockets.delete(id);
        void this.broadcast(id, false);
      }
    });
    void this.broadcast(id, true);
    void this.snapshot(id, socket);
  }
  private async route(source: string, data: string) {
    let value: unknown;
    try {
      value = JSON.parse(data);
    } catch {
      return;
    }
    if (
      !isEnvelope(value) ||
      !("payload" in value) ||
      value.sourceDeviceId !== source ||
      value.targetDeviceId === undefined
    )
      return;
    if (
      !(await this.control.store.pairedDeviceIds(source)).includes(
        value.targetDeviceId,
      )
    )
      return;
    this.deliver(value.targetDeviceId, data);
  }
  private deliver(id: string, data: string) {
    const sockets = [...(this.sockets.get(id) ?? [])].filter(
      (socket) => socket.readyState === WebSocket.OPEN,
    );
    if (sockets.length > 0) {
      for (const socket of sockets) socket.send(data);
      return;
    }
    const items = (this.buffers.get(id) ?? []).filter(
      (item) => item.expiresAt > this.now(),
    );
    items.push({ data, expiresAt: this.now() + this.ttlMs });
    this.buffers.set(id, items.slice(-100));
  }
  private flush(id: string, socket: WebSocket) {
    for (const item of (this.buffers.get(id) ?? []).filter(
      (item) => item.expiresAt > this.now(),
    ))
      socket.send(item.data);
    this.buffers.delete(id);
  }
  private async broadcast(id: string, online: boolean) {
    for (const peer of await this.control.store.pairedDeviceIds(id))
      this.sendPresence(peer, id, online);
  }
  private async snapshot(id: string, socket: WebSocket) {
    for (const peer of await this.control.store.pairedDeviceIds(id))
      socket.send(JSON.stringify(presence(peer, id, this.isOnline(peer))));
  }
  private sendPresence(target: string, source: string, online: boolean) {
    for (const socket of this.sockets.get(target) ?? [])
      if (socket.readyState === WebSocket.OPEN)
        socket.send(JSON.stringify(presence(source, target, online)));
  }
  private pingConnections() {
    for (const sockets of this.sockets.values())
      for (const socket of sockets) {
        if (this.alive.get(socket) === false) {
          socket.terminate();
          continue;
        }
        this.alive.set(socket, false);
        socket.ping();
      }
  }
}
function presence(
  sourceDeviceId: string,
  targetDeviceId: string,
  online: boolean,
): Envelope<{ online: boolean }> {
  return {
    version: 1,
    id: crypto.randomUUID(),
    type: "system.presence",
    sourceDeviceId,
    targetDeviceId,
    timestamp: new Date().toISOString(),
    payload: { online },
  };
}
