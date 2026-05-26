import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createBridgeServer } from "../src/server.mjs";
import { createMockGatewayServer } from "../../mock-gateway/src/server.mjs";

const makeTempDb = () => {
  const dir = fs.mkdtempSync(path.join("/tmp", "bedjet-bridge-api-"));
  return path.join(dir, "bridge.sqlite");
};

const logger = {
  info() {},
  warn() {},
  error() {}
};

const jsonRequest = async (baseUrl, method, pathname, body) => {
  const hasBody = body !== undefined;
  const response = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers: {
      ...(hasBody ? { "Content-Type": "application/json" } : {})
    },
    body: hasBody ? JSON.stringify(body) : undefined
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `HTTP ${response.status}`);
  }
  return payload;
};

test("API state changes persist in simulated mode", async (t) => {
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
  const baseUrl = `http://127.0.0.1:${port}`;

  const pairResult = await jsonRequest(baseUrl, "POST", "/v1/bedjets/left/pair", {
    deviceId: "bedjet-3-left-demo",
    displayName: "BedJet 3 Left Demo"
  });
  assert.equal(pairResult.ok, true);
  assert.equal(app.store.getPairing("left").deviceId, "bedjet-3-left-demo");

  const commandResult = await jsonRequest(baseUrl, "POST", "/v1/bedjets/left/command", { power: "on" });
  assert.equal(commandResult.ok, true);
  const recent = app.store.recentCommands();
  assert.equal(recent[0].action, "manual-command");
  assert.equal(recent[0].request.power, "on");
  assert.equal(recent[0].ok, true);

  await jsonRequest(baseUrl, "POST", "/v1/bedjets/left/release-ble");
  const snapshotAfterRelease = await jsonRequest(baseUrl, "GET", "/v1/bedjets/left");
  assert.equal(snapshotAfterRelease.gateway.status.bleReleased, true);

  await jsonRequest(baseUrl, "POST", "/v1/system/release-ble");
  const leftAfterReleaseAll = await jsonRequest(baseUrl, "GET", "/v1/bedjets/left");
  const rightAfterReleaseAll = await jsonRequest(baseUrl, "GET", "/v1/bedjets/right");
  assert.equal(leftAfterReleaseAll.gateway.status.bleReleased, true);
  assert.equal(rightAfterReleaseAll.gateway.status.bleReleased, true);

  const updatedProfile = await jsonRequest(baseUrl, "PUT", "/v1/profiles/left-hot-high", {
    enabled: false,
    name: "Left Hot High (Updated)"
  });
  assert.equal(updatedProfile.id, "left-hot-high");
  assert.equal(updatedProfile.enabled, false);
  assert.equal(app.store.getProfile("left-hot-high").enabled, false);

  const fastProfileId = "left-fast-state-change";
  app.store.saveProfile({
    id: fastProfileId,
    name: "Left Fast State Change",
    side: "left",
    enabled: true,
    steps: [
      { offsetMinutes: 0, command: { power: "on", mode: "cool", fanStep: 10, targetTemperatureC: 24 } },
      { offsetMinutes: 0.005, command: { power: "on", mode: "cool", fanStep: 6, targetTemperatureC: 23 } }
    ],
    schedule: { enabled: false, localTime: "00:00", daysOfWeek: [] },
    metadata: { description: "test profile", lastTriggeredLocalDate: null }
  });

  await jsonRequest(baseUrl, "POST", `/v1/profiles/${fastProfileId}/start`);
  await new Promise((resolve) => setTimeout(resolve, 120));
  const runAfterStart = app.store.getRun("left");
  assert.equal(runAfterStart.profileId, fastProfileId);
  assert.equal(runAfterStart.lastExecutedStepIndex, 0);

  const commandsAfterStart = app.store.recentCommands();
  assert.equal(commandsAfterStart[0].action, "profile-step");

  await jsonRequest(baseUrl, "POST", `/v1/profiles/${fastProfileId}/stop`);
  await new Promise((resolve) => setTimeout(resolve, 600));
  const runAfterStop = app.store.getRun("left");
  assert.equal(runAfterStop.status, "stopped");

  const commandsAfterStopWait = app.store.recentCommands();
  const profileStepCount = commandsAfterStopWait.filter((entry) => entry.action === "profile-step").length;
  assert.equal(profileStepCount, 1);

  await jsonRequest(baseUrl, "POST", "/v1/bedjets/left/forget");
  assert.equal(app.store.getPairing("left"), null);
  const runAfterForget = app.store.getRun("left");
  assert.equal(runAfterForget.status, "stopped");
  assert.equal(runAfterForget.stopReason, "forgotten");
});

test("API state changes work against mock-gateway (live firmware transport)", async (t) => {
  const secret = "x".repeat(32);
  const gateway = createMockGatewayServer({ host: "127.0.0.1", port: 0 });

  await new Promise((resolve) => gateway.server.listen(gateway.config.port, gateway.config.host, resolve));
  t.after(() => {
    gateway.server.close();
  });

  const gatewayPort = gateway.server.address().port;
  const gatewayBaseUrl = `http://127.0.0.1:${gatewayPort}`;

  await jsonRequest(gatewayBaseUrl, "POST", "/api/v1/claim", { gatewayId: "bedjet-bridge", sharedSecret: secret });

  const app = createBridgeServer({
    config: {
      host: "127.0.0.1",
      port: 0,
      dataPath: makeTempDb(),
      simulateFirmware: false,
      firmwareApiBaseUrl: gatewayBaseUrl,
      firmwareGatewayId: "bedjet-bridge",
      firmwareSharedSecret: secret
    },
    logger
  });

  await app.start();
  t.after(async () => {
    await app.stop();
  });

  const { port } = app.server.address();
  const baseUrl = `http://127.0.0.1:${port}`;

  await jsonRequest(baseUrl, "POST", "/v1/bedjets/left/pair", { deviceId: "bedjet-3-left-demo", displayName: "Left Demo" });
  assert.equal(app.store.getPairing("left").deviceId, "bedjet-3-left-demo");

  await jsonRequest(baseUrl, "POST", "/v1/bedjets/left/command", { power: "on" });
  const recent = app.store.recentCommands();
  assert.equal(recent[0].action, "manual-command");
  assert.equal(recent[0].ok, true);

  await jsonRequest(baseUrl, "POST", "/v1/bedjets/left/forget", {});
  assert.equal(app.store.getPairing("left"), null);
});

test("live bedjet snapshot uses verify path for fresh status", async (t) => {
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
  const baseUrl = `http://127.0.0.1:${port}`;

  await jsonRequest(baseUrl, "POST", "/v1/bedjets/left/pair", {
    deviceId: "bedjet-3-left-demo",
    displayName: "BedJet 3 Left Demo"
  });

  const originalVerify = app.firmware.verify.bind(app.firmware);
  app.firmware.verify = async (side, options) => {
    const verified = await originalVerify(side, options);
    return {
      ...verified,
      status: {
        ...verified.status,
        power: "on",
        mode: "cool"
      }
    };
  };

  const cachedSnapshot = await jsonRequest(baseUrl, "GET", "/v1/bedjets/left");
  assert.equal(cachedSnapshot.gateway.status.power, "off");

  const liveSnapshot = await jsonRequest(baseUrl, "GET", "/v1/bedjets/left?live=1");
  assert.equal(liveSnapshot.gateway.status.power, "on");
});
