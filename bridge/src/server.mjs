import http from "node:http";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { config as defaultConfig } from "./config.mjs";
import { logger as defaultLogger } from "./logger.mjs";
import { BridgeStore } from "./store.mjs";
import { FirmwareClient } from "./firmware-client.mjs";
import { ProfileEngine } from "./profile-engine.mjs";

const allowedSides = new Set(["left", "right"]);

const parseBody = async (request) => {
  const chunks = [];
  for await (const chunk of request) {
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString("utf8");
  return text ? JSON.parse(text) : {};
};

const sendJson = (response, statusCode, payload) => {
  const body = JSON.stringify(payload, null, 2);
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body),
    "Connection": "close"
  });
  response.end(body);
};

const sendHtml = (response, html) => {
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(html),
    "Connection": "close"
  });
  response.end(html);
};

const assertSide = (side) => {
  if (!allowedSides.has(side)) {
    throw new Error(`Invalid side: ${side}`);
  }
};

const normalizeGatewayPairing = (side, gatewaySideState) => {
  if (!gatewaySideState?.paired || !gatewaySideState.deviceId) {
    return null;
  }

  return {
    side,
    deviceId: gatewaySideState.deviceId,
    displayName: gatewaySideState.displayName || `BedJet ${side}`,
    pairedAt: gatewaySideState.pairedAt || null
  };
};

const pairingsEqual = (currentPairing, nextPairing) => {
  if (!currentPairing && !nextPairing) {
    return true;
  }

  if (!currentPairing || !nextPairing) {
    return false;
  }

  return currentPairing.deviceId === nextPairing.deviceId
    && currentPairing.displayName === nextPairing.displayName
    && currentPairing.pairedAt === nextPairing.pairedAt;
};

const syncStorePairingsFromGatewayState = (store, gatewayState) => {
  for (const side of allowedSides) {
    const nextPairing = normalizeGatewayPairing(side, gatewayState?.sides?.[side]);
    const currentPairing = store.getPairing(side);

    if (pairingsEqual(currentPairing, nextPairing)) {
      continue;
    }

    if (nextPairing) {
      store.savePairing(side, nextPairing);
      continue;
    }

    if (currentPairing) {
      store.clearPairing(side);
    }
  }
};

const getSynchronizedGatewayState = async ({ store, firmware }) => {
  const gatewayState = await firmware.getState();
  syncStorePairingsFromGatewayState(store, gatewayState);
  return gatewayState;
};

const buildDashboardHtml = (runtimeConfig) => `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>BedJet Bridge</title>
    <style>
      :root {
        color-scheme: light;
        --bg: #f8f4ee;
        --panel: #fffefc;
        --ink: #1e2428;
        --muted: #566067;
        --accent: #c4552f;
        --accent-soft: #f3d2c8;
        --line: #dfd7cc;
      }
      body {
        margin: 0;
        font-family: "Segoe UI", "Avenir Next", sans-serif;
        background:
          radial-gradient(circle at top right, rgba(196, 85, 47, 0.15), transparent 28%),
          linear-gradient(180deg, #fff8ef 0%, var(--bg) 100%);
        color: var(--ink);
      }
      main {
        max-width: 1100px;
        margin: 0 auto;
        padding: 32px 20px 60px;
      }
      h1 {
        margin: 0 0 10px;
        font-size: 2.3rem;
      }
      p {
        color: var(--muted);
      }
      .grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
        gap: 16px;
      }
      .panel {
        background: var(--panel);
        border: 1px solid var(--line);
        border-radius: 18px;
        padding: 18px;
        box-shadow: 0 20px 45px rgba(60, 45, 30, 0.06);
      }
      button, select {
        border: 1px solid var(--line);
        border-radius: 999px;
        padding: 10px 14px;
        font: inherit;
      }
      button {
        background: var(--accent);
        color: white;
        cursor: pointer;
        margin-right: 8px;
        margin-bottom: 8px;
      }
      button.secondary {
        background: white;
        color: var(--ink);
      }
      pre {
        overflow: auto;
        background: #1f2328;
        color: #f1f5f9;
        border-radius: 14px;
        padding: 14px;
        min-height: 180px;
      }
      .pill {
        display: inline-block;
        padding: 5px 10px;
        border-radius: 999px;
        background: var(--accent-soft);
        color: var(--accent);
        font-weight: 600;
      }
    </style>
  </head>
  <body>
    <main>
      <span class="pill">Bridge ${runtimeConfig.simulateFirmware ? "Simulator" : "Live Firmware"}</span>
      <h1>BedJet SmartThings Bridge</h1>
      <p>Pair left/right BedJets, verify the gateway, launch Nightly Bio, and release BLE for vendor-app handoff.</p>
      <div class="grid">
        <section class="panel">
          <h2>Discovery</h2>
          <button onclick="scan()">Scan</button>
          <select id="candidate"></select>
          <div>
            <button onclick="pair('left')">Pair Left</button>
            <button onclick="pair('right')">Pair Right</button>
          </div>
        </section>
        <section class="panel">
          <h2>Side Actions</h2>
          <div>
            <button class="secondary" onclick="verify('left')">Verify Left</button>
            <button class="secondary" onclick="verify('right')">Verify Right</button>
          </div>
          <div>
            <button class="secondary" onclick="releaseBle('left')">Release Left BLE</button>
            <button class="secondary" onclick="releaseBle('right')">Release Right BLE</button>
          </div>
          <div>
            <button class="secondary" onclick="forgetSide('left')">Forget Left</button>
            <button class="secondary" onclick="forgetSide('right')">Forget Right</button>
          </div>
        </section>
        <section class="panel">
          <h2>Nightly Bio</h2>
          <div>
            <button onclick="startProfile('left-nightly-bio')">Start Left</button>
            <button onclick="startProfile('right-nightly-bio')">Start Right</button>
          </div>
          <div>
            <button class="secondary" onclick="stopProfile('left-nightly-bio')">Stop Left</button>
            <button class="secondary" onclick="stopProfile('right-nightly-bio')">Stop Right</button>
          </div>
          <button class="secondary" onclick="releaseAll()">Release All BLE</button>
        </section>
      </div>
      <section class="panel" style="margin-top: 16px">
        <h2>System Snapshot</h2>
        <pre id="snapshot">Loading...</pre>
      </section>
    </main>
    <script>
      const snapshot = document.getElementById("snapshot");
      const candidate = document.getElementById("candidate");

      async function api(path, options = {}) {
        const response = await fetch(path, {
          headers: { "Content-Type": "application/json" },
          ...options
        });
        const text = await response.text();
        const data = text ? JSON.parse(text) : {};
        if (!response.ok) {
          throw new Error(data.error || response.statusText);
        }
        return data;
      }

      async function refresh() {
        const data = await api("/v1/system");
        snapshot.textContent = JSON.stringify(data, null, 2);
      }

      async function scan() {
        const data = await api("/v1/bedjets/scan", { method: "POST" });
        candidate.innerHTML = "";
        for (const item of data.devices || []) {
          const option = document.createElement("option");
          option.value = item.deviceId;
          option.textContent = \`\${item.displayName} (\${item.deviceId}, RSSI \${item.rssi})\`;
          option.dataset.payload = JSON.stringify(item);
          candidate.appendChild(option);
        }
        await refresh();
      }

      async function pair(side) {
        const selected = candidate.selectedOptions[0];
        if (!selected) return;
        await api(\`/v1/bedjets/\${side}/pair\`, {
          method: "POST",
          body: selected.dataset.payload
        });
        await refresh();
      }

      async function verify(side) {
        await api(\`/v1/bedjets/\${side}/verify\`, { method: "POST" });
        await refresh();
      }

      async function releaseBle(side) {
        await api(\`/v1/bedjets/\${side}/release-ble\`, { method: "POST" });
        await refresh();
      }

      async function releaseAll() {
        await api("/v1/system/release-ble", { method: "POST" });
        await refresh();
      }

      async function forgetSide(side) {
        await api(\`/v1/bedjets/\${side}/forget\`, { method: "POST" });
        await refresh();
      }

      async function startProfile(profileId) {
        await api(\`/v1/profiles/\${profileId}/start\`, { method: "POST" });
        await refresh();
      }

      async function stopProfile(profileId) {
        await api(\`/v1/profiles/\${profileId}/stop\`, { method: "POST" });
        await refresh();
      }

      refresh().catch((error) => {
        snapshot.textContent = error.message;
      });
    </script>
  </body>
</html>`;

const buildSystemSnapshot = async ({ runtimeConfig, store, firmware, engine }) => {
  const gatewayState = await getSynchronizedGatewayState({ store, firmware });
  return {
    bridge: {
      host: runtimeConfig.host,
      port: runtimeConfig.port,
      timezone: runtimeConfig.timezone,
      simulateFirmware: runtimeConfig.simulateFirmware,
      firmwareApiBaseUrl: runtimeConfig.firmwareApiBaseUrl,
      firmwareGatewayId: runtimeConfig.firmwareGatewayId,
      firmwareSharedSecretConfigured: Boolean(runtimeConfig.firmwareSharedSecret)
    },
    pairings: store.getPairings(),
    profiles: store.listProfiles(),
    runs: engine.listRuns(),
    recentCommands: store.recentCommands(),
    gatewayClaim: await firmware.getClaimStatus(),
    gatewayState
  };
};

export const createBridgeServer = (options = {}) => {
  const runtimeConfig = { ...defaultConfig, ...(options.config || {}) };
  const logger = options.logger || defaultLogger;
  const store = new BridgeStore(runtimeConfig.dataPath);
  const firmware = new FirmwareClient({ ...runtimeConfig, logger });
  const engine = new ProfileEngine({
    store,
    firmware,
    logger,
    timezone: runtimeConfig.timezone,
    schedulerIntervalMs: runtimeConfig.schedulerIntervalMs
  });

  const server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);

      if (request.method === "GET" && url.pathname === "/") {
        sendHtml(response, buildDashboardHtml(runtimeConfig));
        return;
      }

      if (request.method === "GET" && url.pathname === "/healthz") {
        sendJson(response, 200, { ok: true, service: "bedjet-bridge" });
        return;
      }

      if (request.method === "GET" && url.pathname === "/v1/system") {
        sendJson(response, 200, await buildSystemSnapshot({ runtimeConfig, store, firmware, engine }));
        return;
      }

      if (request.method === "GET" && url.pathname === "/v1/setup/status") {
        sendJson(response, 200, await buildSystemSnapshot({ runtimeConfig, store, firmware, engine }));
        return;
      }

      if (request.method === "GET" && url.pathname === "/v1/bedjets") {
        const gatewayState = await getSynchronizedGatewayState({ store, firmware });
        sendJson(response, 200, { pairings: store.getPairings(), gatewayState });
        return;
      }

      const bedjetReadMatch = url.pathname.match(/^\/v1\/bedjets\/(left|right)$/);
      if (request.method === "GET" && bedjetReadMatch) {
        const [, side] = bedjetReadMatch;
        const gatewayState = await getSynchronizedGatewayState({ store, firmware });
        sendJson(response, 200, {
          side,
          pairing: store.getPairing(side),
          gateway: gatewayState.sides?.[side] ?? null,
          gatewayConfig: gatewayState.smartthings ?? null,
          run: store.getRun(side)
        });
        return;
      }

      if (request.method === "POST" && url.pathname === "/v1/bedjets/scan") {
        sendJson(response, 200, await firmware.scan());
        return;
      }

      if (request.method === "GET" && url.pathname === "/v1/gateway/claim-status") {
        sendJson(response, 200, await firmware.getClaimStatus());
        return;
      }

      if (request.method === "POST" && url.pathname === "/v1/gateway/claim") {
        const body = await parseBody(request);
        sendJson(response, 200, await firmware.claimGateway(body));
        return;
      }

      const bedjetMatch = url.pathname.match(/^\/v1\/bedjets\/(left|right)\/(pair|verify|forget|release-ble|command)$/);
      if (bedjetMatch) {
        const [, side, action] = bedjetMatch;
        assertSide(side);

        if (action === "pair") {
          const body = await parseBody(request);
          const result = await firmware.pair(side, body);
          store.savePairing(side, result.pairing);
          sendJson(response, 200, result);
          return;
        }

        if (action === "verify") {
          const result = await firmware.verify(side);
          if (result.pairing) {
            store.savePairing(side, result.pairing);
          }
          sendJson(response, 200, result);
          return;
        }

        if (action === "forget") {
          const result = await firmware.forget(side);
          store.clearPairing(side);
          await engine.stopSide(side, "forgotten");
          sendJson(response, 200, result);
          return;
        }

        if (action === "release-ble") {
          sendJson(response, 200, await firmware.releaseBle(side));
          return;
        }

        if (action === "command") {
          const body = await parseBody(request);
          const result = await firmware.sendCommand(side, body);
          store.logCommand(side, "manual-command", body, result, true);
          sendJson(response, 200, result);
          return;
        }
      }

      if (request.method === "POST" && url.pathname === "/v1/system/release-ble") {
        sendJson(response, 200, await firmware.releaseAll());
        return;
      }

      if (request.method === "GET" && url.pathname === "/v1/profiles") {
        sendJson(response, 200, { profiles: store.listProfiles() });
        return;
      }

      const profileMatch = url.pathname.match(/^\/v1\/profiles\/([a-z0-9-]+)(?:\/(start|stop))?$/);
      if (profileMatch) {
        const [, profileId, action] = profileMatch;

        if (request.method === "GET" && !action) {
          const profile = store.getProfile(profileId);
          if (!profile) {
            sendJson(response, 404, { error: "Profile not found" });
            return;
          }
          sendJson(response, 200, profile);
          return;
        }

        if (request.method === "PUT" && !action) {
          const body = await parseBody(request);
          const existing = store.getProfile(profileId);
          if (!existing) {
            sendJson(response, 404, { error: "Profile not found" });
            return;
          }
          const saved = store.saveProfile({
            ...existing,
            ...body,
            id: profileId,
            side: body.side || existing.side
          });
          sendJson(response, 200, saved);
          return;
        }

        if (request.method === "POST" && action === "start") {
          sendJson(response, 200, await engine.startProfile(profileId));
          return;
        }

        if (request.method === "POST" && action === "stop") {
          sendJson(response, 200, await engine.stopProfile(profileId));
          return;
        }
      }

      if (request.method === "GET" && url.pathname === "/v1/runs") {
        sendJson(response, 200, { runs: store.listRuns() });
        return;
      }

      sendJson(response, 404, { error: "Not found" });
    } catch (error) {
      logger.error("Request failed", { error: error.message });
      const statusCode = Number.isInteger(error.status) ? error.status : 500;
      sendJson(response, statusCode, { error: error.message });
    }
  });

  return {
    runtimeConfig,
    store,
    firmware,
    engine,
    server,
    async start() {
      engine.start();
      await new Promise((resolve) => server.listen(runtimeConfig.port, runtimeConfig.host, resolve));
      logger.info("Bridge listening", { host: runtimeConfig.host, port: runtimeConfig.port });
    },
    async stop() {
      engine.stop();
      await new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
      store.close();
    }
  };
};

const currentFile = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === currentFile) {
  const app = createBridgeServer();
  app.start().catch((error) => {
    defaultLogger.error("Failed to start bridge", { error: error.message });
    process.exitCode = 1;
  });
}
