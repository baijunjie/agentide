import type { Envelope } from "@agentide/protocol";
import { WebSocket } from "ws";

export interface RelayClientOptions {
  url: string;
  deviceId: string;
  token: string;
  reconnectDelayMs?: number;
  onMessage?: (envelope: unknown) => void;
}

export class ReconnectingRelayClient {
  private socket: WebSocket | undefined;
  private reconnect: NodeJS.Timeout | undefined;
  private stopped = true;
  private readonly pending: string[] = [];
  private retryAttempt = 0;

  constructor(private readonly options: RelayClientOptions) {}

  async connect(): Promise<void> {
    this.stopped = false;
    await this.open().catch(() => this.scheduleReconnect());
  }

  async disconnect(): Promise<void> {
    this.stopped = true;
    if (this.reconnect !== undefined) clearTimeout(this.reconnect);
    const socket = this.socket;
    this.socket = undefined;
    if (socket === undefined || socket.readyState === WebSocket.CLOSED) return;
    await new Promise<void>((resolve) => {
      socket.once("close", () => resolve());
      socket.close(1000, "client shutdown");
    });
  }

  async send(envelope: Envelope): Promise<void> {
    const data = JSON.stringify(envelope);
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(data);
    else {
      this.pending.push(data);
      if (this.pending.length > 100) this.pending.shift();
    }
  }

  private async open(): Promise<void> {
    const url = new URL("/connect", this.options.url);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.searchParams.set("deviceId", this.options.deviceId);
    const socket = new WebSocket(url, {
      headers: { authorization: `Bearer ${this.options.token}` },
    });
    this.socket = socket;
    await new Promise<void>((resolve, reject) => {
      socket.once("open", () => {
        this.retryAttempt = 0;
        for (const message of this.pending.splice(0)) socket.send(message);
        resolve();
      });
      socket.once("error", reject);
    });
    socket.on("message", (data) => {
      try {
        this.options.onMessage?.(JSON.parse(data.toString()));
      } catch {
        /* Ignore malformed relay frames. */
      }
    });
    socket.once("close", () => {
      if (this.socket === socket) this.socket = undefined;
      this.scheduleReconnect();
    });
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnect !== undefined) return;
    const base = this.options.reconnectDelayMs ?? 1_000;
    const delay = Math.min(base * 2 ** this.retryAttempt, 30_000);
    this.retryAttempt += 1;
    this.reconnect = setTimeout(() => {
      this.reconnect = undefined;
      void this.open().catch(() => this.scheduleReconnect());
    }, delay);
  }
}
