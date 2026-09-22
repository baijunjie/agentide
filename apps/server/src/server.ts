import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import { isEnvelope } from "@agentide/protocol";

const MAX_ENVELOPE_BYTES = 1024 * 1024;

export function createRelayServer() {
  return createServer(async (request, response) => {
    if (request.method === "GET" && request.url === "/health") {
      sendJson(response, 200, { status: "ok" });
      return;
    }

    if (request.method === "POST" && request.url === "/relay") {
      await acceptRelayEnvelope(request, response);
      return;
    }

    sendJson(response, 404, { error: "not_found" });
  });
}

async function acceptRelayEnvelope(request: IncomingMessage, response: ServerResponse) {
  try {
    const body = await readBody(request);
    const envelope: unknown = JSON.parse(body);
    if (!isEnvelope(envelope)) {
      sendJson(response, 400, { error: "invalid_envelope" });
      return;
    }

    // The relay validates routing metadata only. Payload inspection and persistence belong to neither its control plane nor its trust boundary.
    sendJson(response, 202, { accepted: true, id: envelope.id });
  } catch (error) {
    const status = error instanceof PayloadTooLargeError ? 413 : 400;
    sendJson(response, status, { error: status === 413 ? "payload_too_large" : "invalid_json" });
  }
}

async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let byteLength = 0;

  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    byteLength += buffer.length;
    if (byteLength > MAX_ENVELOPE_BYTES) {
      throw new PayloadTooLargeError();
    }
    chunks.push(buffer);
  }

  return Buffer.concat(chunks).toString("utf8");
}

function sendJson(response: ServerResponse, status: number, body: unknown) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

class PayloadTooLargeError extends Error {}
