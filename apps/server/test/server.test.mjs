import assert from "node:assert/strict";
import test from "node:test";

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
