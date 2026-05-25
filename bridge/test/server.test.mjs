import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { createBridgeServer, validateRuntimeConfig } from "../src/server.mjs";
import { BridgeStore } from "../src/store.mjs";
import { FirmwareClient } from "../src/firmware-client.mjs";
import { ProfileEngine } from "../src/profile-engine.mjs";
import { createMockGatewayServer } from "../../mock-gateway/src/server.mjs";

const makeTempDb = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bedjet-bridge-"));
  return path.join(dir, "bridge.sqlite");
};

const logger = {
  info() {},
  warn() {},
  error() {}
};

const requestRaw = (port, pathname, { method = "GET", headers = {}, body } = {}) => new Promise((resolve, reject) => {
  const request = http.request(
    {
      host: "127.0.0.1",
      port,
      path: pathname,
      method,
      headers
    },
    (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        resolve({
          statusCode: response.statusCode,
          payload: text ? JSON.parse(text) : {}
        });
      });
    }
  );
  request.on("error", reject);
  if (body !== undefined) {
    request.write(body);
  }
  request.end();
});

test("store seeds default profiles and firmware simulator scans", async () => {
  const store = new BridgeStore(makeTempDb());
  const firmware = new FirmwareClient({
    simulateFirmware: true,
    firmwareApiBaseUrl: "http://bedjet-gateway.local",
    logger
  });

  const profiles = store.listProfiles();
  assert.equal(profiles.length, 4);
  assert.deepEqual(
    profiles.map((profile) => profile.id).sort(),
    ["left-hot-high", "left-nightly-bio", "right-hot-high", "right-nightly-bio"]
  );

  const scan = await firmware.scan();
  assert.equal(scan.devices.length, 2);
  assert.equal(scan.devices[0].deviceId, "bedjet-3-left-demo");

  store.close();
});

test("hot-high profile executes a single heating step", async () => {
  const store = new BridgeStore(makeTempDb());
  const firmware = new FirmwareClient({
    simulateFirmware: true,
    firmwareApiBaseUrl: "http://bedjet-gateway.local",
    logger
  });

  const pairResult = await firmware.pair("left", {
    deviceId: "bedjet-3-left-demo",
    displayName: "BedJet 3 Left Demo"
  });
  store.savePairing("left", pairResult.pairing);

  const engine = new ProfileEngine({
    store,
    firmware,
    logger,
    timezone: "America/Los_Angeles",
    schedulerIntervalMs: 30_000
  });

  await engine.startProfile("left-hot-high");
  await new Promise((resolve) => setTimeout(resolve, 150));

  const commands = store.recentCommands();
  assert.equal(commands.length, 1);
  assert.equal(commands[0].action, "profile-step");
  assert.equal(commands[0].request.mode, "heat");
  assert.equal(commands[0].request.fanStep, 18);
  assert.equal(commands[0].request.targetTemperatureC, 32);
  assert.equal(commands[0].ok, true);

  engine.stop();
  store.close();
});

test("profile engine starts a profile against the simulated firmware", async () => {
  const store = new BridgeStore(makeTempDb());
  const firmware = new FirmwareClient({
    simulateFirmware: true,
    firmwareApiBaseUrl: "http://bedjet-gateway.local",
    logger
  });

  const pairResult = await firmware.pair("left", {
    deviceId: "bedjet-3-left-demo",
    displayName: "BedJet 3 Left Demo"
  });
  store.savePairing("left", pairResult.pairing);

  const engine = new ProfileEngine({
    store,
    firmware,
    logger,
    timezone: "America/Los_Angeles",
    schedulerIntervalMs: 30_000
  });

  const run = await engine.startProfile("left-nightly-bio");
  assert.equal(run.status, "running");

  await new Promise((resolve) => setTimeout(resolve, 150));

  const updatedRun = store.getRun("left");
  assert.equal(updatedRun.lastExecutedStepIndex, 0);

  const commands = store.recentCommands();
  assert.equal(commands.length, 1);
  assert.equal(commands[0].action, "profile-step");
  assert.equal(commands[0].ok, true);

  engine.stop();
  store.close();
});

test("profile engine immediately completes empty profiles", async () => {
  const store = new BridgeStore(makeTempDb());
  const firmware = new FirmwareClient({
    simulateFirmware: true,
    firmwareApiBaseUrl: "http://bedjet-gateway.local",
    logger
  });

  store.saveProfile({
    id: "left-empty",
    name: "Left Empty",
    side: "left",
    enabled: true,
    steps: [],
    schedule: { enabled: false, localTime: "00:00", daysOfWeek: [] },
    metadata: {}
  });

  const engine = new ProfileEngine({
    store,
    firmware,
    logger,
    timezone: "America/Los_Angeles",
    schedulerIntervalMs: 30_000
  });

  const run = await engine.startProfile("left-empty");
  assert.equal(run.status, "completed");
  assert.equal(run.lastExecutedStepIndex, -1);
  assert.ok(run.completedAt);

  engine.stop();
  store.close();
});

test("profile engine cancels remaining timers when run is stopped", async () => {
  const store = new BridgeStore(makeTempDb());
  const firmware = new FirmwareClient({
    simulateFirmware: true,
    firmwareApiBaseUrl: "http://bedjet-gateway.local",
    logger
  });

  const pairResult = await firmware.pair("left", {
    deviceId: "bedjet-3-left-demo",
    displayName: "BedJet 3 Left Demo"
  });
  store.savePairing("left", pairResult.pairing);

  store.saveProfile({
    id: "left-cancelled-run",
    name: "Left Cancelled Run",
    side: "left",
    enabled: true,
    steps: [
      { offsetMinutes: 0, command: { power: "on", mode: "cool", fanStep: 8, targetTemperatureC: 24 } },
      { offsetMinutes: 0.01, command: { power: "on", mode: "cool", fanStep: 4, targetTemperatureC: 22 } }
    ],
    schedule: { enabled: false, localTime: "00:00", daysOfWeek: [] },
    metadata: {}
  });

  const engine = new ProfileEngine({
    store,
    firmware,
    logger,
    timezone: "America/Los_Angeles",
    schedulerIntervalMs: 30_000
  });

  await engine.startProfile("left-cancelled-run");
  await new Promise((resolve) => setTimeout(resolve, 120));
  await engine.stopProfile("left-cancelled-run");
  await new Promise((resolve) => setTimeout(resolve, 620));

  const run = store.getRun("left");
  const profileStepCommands = store.recentCommands().filter((entry) => entry.action === "profile-step");

  assert.equal(run.status, "stopped");
  assert.equal(profileStepCommands.length, 1);

  engine.stop();
  store.close();
});

test("bridge exposes version and readiness endpoints in simulated mode", async (t) => {
  const app = createBridgeServer({
    config: {
      host: "127.0.0.1",
      port: 0,
      dataPath: makeTempDb(),
      simulateFirmware: true
    },
    logger
  });

  await app.firmware.claimGateway({ gatewayId: "bedjet-bridge" });
  await app.start();
  t.after(async () => {
    await app.stop();
  });

  const { port } = app.server.address();

  const versionResponse = await fetch(`http://127.0.0.1:${port}/v1/version`);
  assert.equal(versionResponse.status, 200);
  const version = await versionResponse.json();
  assert.equal(version.service, "bedjet-bridge");
  assert.equal(version.version, "0.1.0");

  const readinessResponse = await fetch(`http://127.0.0.1:${port}/readyz`);
  assert.equal(readinessResponse.status, 200);
  const readiness = await readinessResponse.json();
  assert.equal(readiness.ok, true);
  assert.equal(readiness.gatewayClaimed, true);
});

test("bridge rejects oversized JSON bodies", async (t) => {
  const app = createBridgeServer({
    config: {
      host: "127.0.0.1",
      port: 0,
      dataPath: makeTempDb(),
      simulateFirmware: true
    },
    logger
  });

  await app.start();
  t.after(async () => {
    await app.stop();
  });

  const { port } = app.server.address();
  const largeDeviceId = "x".repeat(20_000);
  const response = await fetch(`http://127.0.0.1:${port}/v1/bedjets/left/pair`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ deviceId: largeDeviceId, displayName: "Too Big" })
  });

  assert.equal(response.status, 413);
  const payload = await response.json();
  assert.match(payload.error, /exceeds 16384 bytes/);
});

test("bridge shared-secret auth enforces X-Bridge-Token while keeping /healthz open", async (t) => {
  const app = createBridgeServer({
    config: {
      host: "127.0.0.1",
      port: 0,
      dataPath: makeTempDb(),
      simulateFirmware: true,
      bridgeSharedSecret: "bridge-secret-value"
    },
    logger
  });

  await app.start();
  t.after(async () => {
    await app.stop();
  });

  const { port } = app.server.address();

  const healthz = await fetch(`http://127.0.0.1:${port}/healthz`);
  assert.equal(healthz.status, 200);

  const unauthenticated = await fetch(`http://127.0.0.1:${port}/v1/version`);
  assert.equal(unauthenticated.status, 401);

  const multiValueHeader = await requestRaw(port, "/v1/version", {
    headers: {
      "X-Bridge-Token": ["bridge-secret-value", "ignored-secondary-token"]
    }
  });
  assert.equal(multiValueHeader.statusCode, 200);
});

test("bridge returns 502 for firmware non-JSON responses without echoing upstream body", async (t) => {
  const firmwareServer = http.createServer((request, response) => {
    if (request.method === "GET" && request.url === "/api/v1/state") {
      response.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      response.end("sensitive-gateway-body");
      return;
    }

    response.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    response.end(JSON.stringify({ claimed: true, gatewayId: "bedjet-bridge", sides: { left: {}, right: {} } }));
  });

  await new Promise((resolve) => firmwareServer.listen(0, "127.0.0.1", resolve));
  t.after(() => {
    firmwareServer.close();
  });

  const firmwarePort = firmwareServer.address().port;
  const app = createBridgeServer({
    config: {
      host: "127.0.0.1",
      port: 0,
      dataPath: makeTempDb(),
      simulateFirmware: false,
      firmwareApiBaseUrl: `http://127.0.0.1:${firmwarePort}`,
      firmwareGatewayId: "bedjet-bridge",
      firmwareSharedSecret: "1234567890abcdef"
    },
    logger
  });

  await app.start();
  t.after(async () => {
    await app.stop();
  });

  const { port } = app.server.address();
  const response = await fetch(`http://127.0.0.1:${port}/v1/bedjets`);
  const payload = await response.json();

  assert.equal(response.status, 502);
  assert.match(payload.error, /Firmware returned invalid JSON/);
  assert.doesNotMatch(payload.error, /sensitive-gateway-body/);
});

test("bridge rejects malformed or no-op command payloads", async (t) => {
  const app = createBridgeServer({
    config: {
      host: "127.0.0.1",
      port: 0,
      dataPath: makeTempDb(),
      simulateFirmware: true
    },
    logger
  });

  await app.start();
  t.after(async () => {
    await app.stop();
  });

  const { port } = app.server.address();

  const emptyBodyResponse = await fetch(`http://127.0.0.1:${port}/v1/bedjets/left/command`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({})
  });
  assert.equal(emptyBodyResponse.status, 400);

  const nullPowerResponse = await fetch(`http://127.0.0.1:${port}/v1/bedjets/left/command`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ power: null })
  });
  assert.equal(nullPowerResponse.status, 400);

  const invalidFanResponse = await fetch(`http://127.0.0.1:${port}/v1/bedjets/left/command`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ fanStep: 0 })
  });
  assert.equal(invalidFanResponse.status, 400);
});

test("bridge validation fails in live mode without required firmware auth config", () => {
  assert.throws(() => {
    validateRuntimeConfig({
      host: "127.0.0.1",
      port: 8787,
      timezone: "America/Los_Angeles",
      dataPath: makeTempDb(),
      firmwareApiBaseUrl: "http://bedjet-gateway.local",
      firmwareGatewayId: "bedjet-bridge",
      firmwareSharedSecret: "",
      simulateFirmware: false,
      schedulerIntervalMs: 30_000,
      firmwareRequestTimeoutMs: 4_000,
      firmwareRequestRetries: 2,
      gatewayStateCacheMs: 1_000
    });
  }, /Missing required live bridge config: FIRMWARE_SHARED_SECRET/);
});

test("bridge live mode preserves pairing readback against the gateway state endpoint", async (t) => {
  const mockGateway = createMockGatewayServer({ host: "127.0.0.1", port: 0 });
  await new Promise((resolve) => mockGateway.server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    await new Promise((resolve, reject) => {
      mockGateway.server.close((error) => (error ? reject(error) : resolve()));
    });
  });

  const mockPort = mockGateway.server.address().port;
  const gatewayId = "bedjet-bridge";
  const sharedSecret = "0123456789abcdef0123456789abcdef";
  const app = createBridgeServer({
    config: {
      host: "127.0.0.1",
      port: 0,
      dataPath: makeTempDb(),
      simulateFirmware: false,
      firmwareApiBaseUrl: `http://127.0.0.1:${mockPort}`,
      firmwareGatewayId: gatewayId,
      firmwareSharedSecret: sharedSecret
    },
    logger
  });

  await app.firmware.claimGateway({ gatewayId, sharedSecret });
  await app.start();
  t.after(async () => {
    await app.stop();
  });

  const bridgePort = app.server.address().port;
  const pairResponse = await fetch(`http://127.0.0.1:${bridgePort}/v1/bedjets/left/pair`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      deviceId: "bedjet-3-left-demo",
      displayName: "BedJet 3 Left Demo"
    })
  });
  assert.equal(pairResponse.status, 200);

  const bedjetResponse = await fetch(`http://127.0.0.1:${bridgePort}/v1/bedjets/left`);
  assert.equal(bedjetResponse.status, 200);

  const bedjet = await bedjetResponse.json();
  assert.equal(bedjet.pairing?.deviceId, "bedjet-3-left-demo");
  assert.equal(bedjet.gateway?.deviceId, "bedjet-3-left-demo");
  assert.equal(bedjet.gateway?.paired, true);

  const allBedjetsResponse = await fetch(`http://127.0.0.1:${bridgePort}/v1/bedjets`);
  assert.equal(allBedjetsResponse.status, 200);

  const allBedjets = await allBedjetsResponse.json();
  assert.equal(allBedjets.pairings.left?.deviceId, "bedjet-3-left-demo");
});
