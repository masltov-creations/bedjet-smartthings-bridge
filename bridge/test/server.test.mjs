import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
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
  assert.equal(profiles.length, 2);
  assert.deepEqual(
    profiles.map((profile) => profile.id).sort(),
    ["left-nightly-bio", "right-nightly-bio"]
  );

  const scan = await firmware.scan();
  assert.equal(scan.devices.length, 2);
  assert.equal(scan.devices[0].deviceId, "bedjet-3-left-demo");

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
