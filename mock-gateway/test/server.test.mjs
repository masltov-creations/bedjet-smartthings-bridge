import assert from "node:assert/strict";
import test from "node:test";
import { createMockGatewayServer } from "../src/server.mjs";

test("mock gateway server factory exposes expected defaults", () => {
  const { server, state, config } = createMockGatewayServer({
    host: "127.0.0.1",
    port: 8789,
    hostname: "bedjet-gateway-mock"
  });

  assert.equal(typeof server.listen, "function");
  assert.equal(config.port, 8789);
  assert.equal(state.network.hostname, "bedjet-gateway-mock");
  assert.equal(state.claim.claimed, false);
  assert.equal(state.devices.length, 2);
});
