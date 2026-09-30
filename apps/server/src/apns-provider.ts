import { connect, type ClientHttp2Session, type ClientHttp2Stream } from "node:http2";
import { createHash, createPrivateKey, sign } from "node:crypto";
import type { NotificationIntent, PushEnvironment } from "@agentide/protocol";

export type PushResult =
  | { kind: "success" }
  | { kind: "invalid_token" }
  | { kind: "rate_limited" }
  | { kind: "transient_failure" }
  | { kind: "permanent_failure" };

export interface PushMessage {
  token: string;
  environment: PushEnvironment;
  intent: NotificationIntent;
  idempotencyKey: string;
}

export interface APNsProvider {
  send(message: PushMessage): Promise<PushResult>;
}

export interface APNsResponse {
  status: number;
  reason?: string;
}

export interface APNsTransport {
  send(authority: string, headers: Record<string, string>, body: string, signal: AbortSignal): Promise<APNsResponse>;
}

export interface TokenAPNsProviderOptions {
  keyId: string;
  teamId: string;
  topic: string;
  privateKey: string;
  now?: () => Date;
  requestTimeoutMilliseconds?: number;
  transport?: APNsTransport;
}

export class TokenAPNsProvider implements APNsProvider {
  private readonly now: () => Date;
  private readonly transport: APNsTransport;
  private readonly requestTimeoutMilliseconds: number;
  private jwt: { value: string; issuedAt: number } | undefined;

  constructor(private readonly options: TokenAPNsProviderOptions) {
    this.now = options.now ?? (() => new Date());
    this.transport = options.transport ?? new Http2APNsTransport();
    this.requestTimeoutMilliseconds = options.requestTimeoutMilliseconds ?? 10_000;
  }

  async send(message: PushMessage): Promise<PushResult> {
    const authority = message.environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.requestTimeoutMilliseconds);
    try {
      const authorizationToken = this.authorizationToken();
      const response = await this.transport.send(authority, {
        ":method": "POST",
        ":path": `/3/device/${encodeURIComponent(message.token)}`,
        authorization: `bearer ${authorizationToken}`,
        "apns-topic": this.options.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-collapse-id": createHash("sha256").update(message.idempotencyKey).digest("hex"),
      }, notificationPayload(message.intent), controller.signal);
      return this.resultFor(response, authorizationToken);
    } catch {
      return { kind: "transient_failure" };
    } finally {
      clearTimeout(timeout);
    }
  }

  private authorizationToken(): string {
    const nowSeconds = Math.floor(this.now().getTime() / 1_000);
    if (this.jwt !== undefined && nowSeconds - this.jwt.issuedAt < 50 * 60) return this.jwt.value;
    const header = base64url(JSON.stringify({ alg: "ES256", kid: this.options.keyId }));
    const claims = base64url(JSON.stringify({ iss: this.options.teamId, iat: nowSeconds }));
    const signingInput = `${header}.${claims}`;
    const signature = sign("sha256", Buffer.from(signingInput), {
      key: createPrivateKey(this.options.privateKey),
      dsaEncoding: "ieee-p1363",
    });
    const value = `${signingInput}.${signature.toString("base64url")}`;
    this.jwt = { value, issuedAt: nowSeconds };
    return value;
  }

  private resultFor(response: APNsResponse, authorizationToken: string): PushResult {
    if (response.status === 200) return { kind: "success" };
    if (response.status === 429) return { kind: "rate_limited" };
    if (response.status >= 500) return { kind: "transient_failure" };
    if (response.reason === "ExpiredProviderToken") {
      // A later request may have already refreshed the shared cache while this
      // request was in flight; an old APNs response must not evict that JWT.
      if (this.jwt?.value === authorizationToken) this.jwt = undefined;
      return { kind: "transient_failure" };
    }
    if (response.reason === "BadDeviceToken" || response.reason === "Unregistered") {
      return { kind: "invalid_token" };
    }
    if (isPermanentPayloadFailure(response.reason)) return { kind: "permanent_failure" };
    // APNs can add response reasons. Unknown client errors must retain the outbox item
    // because acknowledging a provider or topic misconfiguration loses the notification.
    return { kind: "transient_failure" };
  }
}

export class UnavailableAPNsProvider implements APNsProvider {
  async send(): Promise<PushResult> {
    return { kind: "transient_failure" };
  }
}

export type Http2SessionFactory = (authority: string) => ClientHttp2Session;

export class Http2APNsTransport implements APNsTransport {
  constructor(private readonly createSession: Http2SessionFactory = connect) {}

  async send(authority: string, headers: Record<string, string>, body: string, signal: AbortSignal): Promise<APNsResponse> {
    if (signal.aborted) throw new Error("APNs request aborted");
    const session = this.createSession(authority);
    return sendRequest(session, headers, body, signal);
  }
}

function notificationPayload(intent: NotificationIntent): string {
  const body = intent.category === "approval_waiting"
    ? "Approval required"
    : intent.category === "question_waiting"
      ? "Question requires your response"
      : intent.category === "task_completed"
        ? "Task completed"
        : "Task failed";
  return JSON.stringify({
    aps: {
      alert: { title: intent.projectName, subtitle: intent.sessionTitle, body },
      sound: "default",
    },
    agentide: {
      projectId: intent.projectId,
      sessionId: intent.sessionId,
      sequence: intent.sequence,
      category: intent.category,
      projectName: intent.projectName,
      sessionTitle: intent.sessionTitle,
      createdAt: intent.createdAt,
    },
  });
}

function sendRequest(
  session: ClientHttp2Session,
  headers: Record<string, string>,
  body: string,
  signal: AbortSignal,
): Promise<APNsResponse> {
  return new Promise((resolve, reject) => {
    let request: ClientHttp2Stream | undefined;
    let settled = false;
    let status = 0;
    let data = "";
    const settle = (callback: () => void, closeSession = true): void => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", abort);
      callback();
      // Keep the session error listener until close: destroying an HTTP/2 session
      // can emit its error after the stream settles, which would otherwise be unhandled.
      if (closeSession) session.close();
    };
    const fail = (error: Error, closeSession = true): void => settle(() => reject(error), closeSession);
    const abort = (): void => {
      const error = new Error("APNs request aborted");
      fail(error, false);
      session.destroy(error);
    };
    const onSessionError = (error: Error): void => fail(error);
    const onSessionClose = (): void => {
      session.removeListener("error", onSessionError);
      request?.removeAllListeners();
      if (!settled) fail(new Error("APNs connection closed before a response"));
    };
    session.on("error", onSessionError);
    session.once("close", onSessionClose);
    signal.addEventListener("abort", abort, { once: true });
    try {
      request = session.request(headers);
      request.setEncoding("utf8");
      request.on("response", (responseHeaders) => {
        status = Number(responseHeaders[":status"] ?? 0);
      });
      request.on("data", (chunk: string) => { data += chunk; });
      request.on("error", fail);
      request.on("end", () => {
        let reason: string | undefined;
        try {
          const value = JSON.parse(data) as { reason?: unknown };
          if (typeof value.reason === "string") reason = value.reason;
        } catch { /* APNs success responses have no body. */ }
        settle(() => resolve({ status, ...(reason === undefined ? {} : { reason }) }));
      });
      request.end(body);
    } catch (error) {
      fail(error instanceof Error ? error : new Error("APNs request failed"));
    }
  });
}

function base64url(value: string): string {
  return Buffer.from(value).toString("base64url");
}

function isPermanentPayloadFailure(reason: string | undefined): boolean {
  return reason === "BadPayload" ||
    reason === "PayloadEmpty" ||
    reason === "PayloadTooLarge" ||
    reason === "BadCollapseId" ||
    reason === "BadExpirationDate" ||
    reason === "BadMessageId" ||
    reason === "BadPriority";
}
