import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createBridgeServer, validateRuntimeConfig } from "../src/server.mjs";
import { BridgeStore } from "../src/store.mjs";
import { FirmwareClient } from "../src/firmware-client.mjs";
import { ProfileEngine } from "../src/profile-engine.mjs";

const makeTempDb = () => {
  const dir = fs.mkdtempSync(path.join("/tmp", "bedjet-bridge-"));
  return path.join(dir, "bridge.sqlite");
};

const logger = {
  info() {},
  warn() {},
  error() {}
};

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
      schedulerIntervalMs: 30_000
    });
  }, /Missing required live bridge config: FIRMWARE_SHARED_SECRET/);
});
