import http from "node:http";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { config as defaultConfig } from "./config.mjs";
import { logger as defaultLogger } from "./logger.mjs";
import { BridgeStore } from "./store.mjs";
import { FirmwareClient } from "./firmware-client.mjs";
import { ProfileEngine } from "./profile-engine.mjs";

const allowedSides = new Set(["left", "right"]);
const currentFile = fileURLToPath(import.meta.url);
const currentDir = path.dirname(currentFile);
const bridgePackage = JSON.parse(fs.readFileSync(path.resolve(currentDir, "../package.json"), "utf8"));
const maxJsonBodyBytes = 16 * 1024;

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "HttpError";
    this.status = status;
  }
}

const parseBody = async (request) => {
  const contentLengthHeader = request.headers["content-length"];
  if (contentLengthHeader) {
    const contentLength = Number.parseInt(contentLengthHeader, 10);
    if (Number.isFinite(contentLength) && contentLength > maxJsonBodyBytes) {
      throw new HttpError(413, `JSON body exceeds ${maxJsonBodyBytes} bytes`);
    }
  }

  const chunks = [];
  let totalBytes = 0;
  for await (const chunk of request) {
    totalBytes += chunk.length;
    if (totalBytes > maxJsonBodyBytes) {
      throw new HttpError(413, `JSON body exceeds ${maxJsonBodyBytes} bytes`);
    }
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString("utf8");
  if (!text) {
    return {};
  }

  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, "Invalid JSON body");
  }
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

const assertSide = (side) => {
  if (!allowedSides.has(side)) {
    throw new HttpError(400, `Invalid side: ${side}`);
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

const getSynchronizedGatewayState = async ({ store, firmware, cache, firmwareOptions }) => {
  const now = Date.now();
  if (cache?.value && Number.isFinite(cache.fetchedAt) && now - cache.fetchedAt < cache.ttlMs) {
    return cache.value;
  }

  if (cache?.inFlight) {
    return cache.inFlight;
  }

  const promise = (async () => {
    const gatewayState = await firmware.getState(firmwareOptions);
    syncStorePairingsFromGatewayState(store, gatewayState);
    if (cache) {
      cache.value = gatewayState;
      cache.fetchedAt = Date.now();
    }
    return gatewayState;
  })();

  if (cache) {
    cache.inFlight = promise.finally(() => {
      cache.inFlight = null;
    });
    return cache.inFlight;
  }

  return promise;
};

const requireBridgeAuth = ({ runtimeConfig, request, pathname }) => {
  if (!runtimeConfig.bridgeSharedSecret) {
    return;
  }

  if (pathname === "/healthz") {
    return;
  }

  const token = request.headers["x-bridge-token"] || "";
  if (token !== runtimeConfig.bridgeSharedSecret) {
    throw new HttpError(401, "Unauthorized");
  }
};

const getFirmwareRequestOptions = ({ runtimeConfig, request, response }) => {
  const controller = new AbortController();

  const abort = () => controller.abort(new Error("Client disconnected"));
  request.on("aborted", abort);
  response.on("close", () => {
    if (!response.writableEnded) {
      abort();
    }
  });

  return {
    signal: controller.signal,
    timeoutMs: runtimeConfig.firmwareRequestTimeoutMs
  };
};

export const validateRuntimeConfig = (runtimeConfig) => {
  if (!Number.isInteger(runtimeConfig.port) || runtimeConfig.port < 0 || runtimeConfig.port > 65535) {
    throw new Error("PORT must be an integer between 0 and 65535");
  }

  if (!Number.isInteger(runtimeConfig.schedulerIntervalMs) || runtimeConfig.schedulerIntervalMs < 1_000) {
    throw new Error("SCHEDULER_INTERVAL_MS must be at least 1000");
  }

  if (!Number.isInteger(runtimeConfig.firmwareRequestTimeoutMs) || runtimeConfig.firmwareRequestTimeoutMs < 250) {
    throw new Error("FIRMWARE_REQUEST_TIMEOUT_MS must be at least 250");
  }

  if (!Number.isInteger(runtimeConfig.firmwareRequestRetries) || runtimeConfig.firmwareRequestRetries < 0 || runtimeConfig.firmwareRequestRetries > 10) {
    throw new Error("FIRMWARE_REQUEST_RETRIES must be between 0 and 10");
  }

  if (!Number.isInteger(runtimeConfig.gatewayStateCacheMs) || runtimeConfig.gatewayStateCacheMs < 0 || runtimeConfig.gatewayStateCacheMs > 60_000) {
    throw new Error("GATEWAY_STATE_CACHE_MS must be between 0 and 60000");
  }

  if (runtimeConfig.simulateFirmware) {
    return runtimeConfig;
  }

  const missing = [];
  if (!runtimeConfig.firmwareApiBaseUrl) {
    missing.push("FIRMWARE_API_BASE_URL");
  }
  if (!runtimeConfig.firmwareGatewayId) {
    missing.push("FIRMWARE_GATEWAY_ID");
  }
  if (!runtimeConfig.firmwareSharedSecret) {
    missing.push("FIRMWARE_SHARED_SECRET");
  }
  if (missing.length > 0) {
    throw new Error(`Missing required live bridge config: ${missing.join(", ")}`);
  }

  try {
    const url = new URL(runtimeConfig.firmwareApiBaseUrl);
    if (!["http:", "https:"].includes(url.protocol)) {
      throw new Error("bad protocol");
    }
  } catch {
    throw new Error("FIRMWARE_API_BASE_URL must be a valid http or https URL");
  }

  if (runtimeConfig.firmwareSharedSecret.length < 16) {
    throw new Error("FIRMWARE_SHARED_SECRET must be at least 16 characters in live mode");
  }

  return runtimeConfig;
};

const buildVersionSnapshot = (runtimeConfig) => ({
  ok: true,
  service: "bedjet-bridge",
  version: bridgePackage.version,
  nodeVersion: process.version,
  simulateFirmware: runtimeConfig.simulateFirmware
});

const buildReadinessSnapshot = async ({ runtimeConfig, firmware }) => {
  try {
    const firmwareOptions = { timeoutMs: runtimeConfig.firmwareRequestTimeoutMs };
    const gatewayClaim = await firmware.getClaimStatus(firmwareOptions);
    const gatewayState = await firmware.getState(firmwareOptions);
    return {
      ok: Boolean(gatewayClaim?.claimed),
      service: "bedjet-bridge",
      version: bridgePackage.version,
      simulateFirmware: runtimeConfig.simulateFirmware,
      gatewayReachable: true,
      gatewayClaimed: Boolean(gatewayClaim?.claimed),
      gatewayId: gatewayClaim?.gatewayId || "",
      pairedSides: ["left", "right"].filter((side) => Boolean(gatewayState?.sides?.[side]?.paired))
    };
  } catch (error) {
    return {
      ok: false,
      service: "bedjet-bridge",
      version: bridgePackage.version,
      simulateFirmware: runtimeConfig.simulateFirmware,
      gatewayReachable: false,
      gatewayClaimed: false,
      error: error.message
    };
  }
};

const buildSystemSnapshot = async ({ runtimeConfig, store, firmware, engine, cache, firmwareOptions }) => {
  const gatewayState = await getSynchronizedGatewayState({ store, firmware, cache, firmwareOptions });
  return {
    bridge: {
      host: runtimeConfig.host,
      port: runtimeConfig.port,
      timezone: runtimeConfig.timezone,
      simulateFirmware: runtimeConfig.simulateFirmware,
      firmwareApiBaseUrl: runtimeConfig.firmwareApiBaseUrl,
      firmwareGatewayId: runtimeConfig.firmwareGatewayId,
      firmwareSharedSecretConfigured: Boolean(runtimeConfig.firmwareSharedSecret),
      bridgeSharedSecretConfigured: Boolean(runtimeConfig.bridgeSharedSecret),
      firmwareRequestTimeoutMs: runtimeConfig.firmwareRequestTimeoutMs,
      firmwareRequestRetries: runtimeConfig.firmwareRequestRetries,
      gatewayStateCacheMs: runtimeConfig.gatewayStateCacheMs
    },
    pairings: store.getPairings(),
    profiles: store.listProfiles(),
    runs: engine.listRuns(),
    recentCommands: store.recentCommands(),
    gatewayClaim: await firmware.getClaimStatus(firmwareOptions),
    gatewayState
  };
};

export const createBridgeServer = (options = {}) => {
  const runtimeConfig = validateRuntimeConfig({ ...defaultConfig, ...(options.config || {}) });
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

  const gatewayStateCache = {
    ttlMs: runtimeConfig.gatewayStateCacheMs,
    fetchedAt: 0,
    value: null,
    inFlight: null
  };

  const server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);
      requireBridgeAuth({ runtimeConfig, request, pathname: url.pathname });
      const firmwareOptions = getFirmwareRequestOptions({ runtimeConfig, request, response });
      const stateFirmwareOptions = { timeoutMs: runtimeConfig.firmwareRequestTimeoutMs };

      if (request.method === "GET" && url.pathname === "/healthz") {
        sendJson(response, 200, { ok: true, service: "bedjet-bridge" });
        return;
      }

      if (request.method === "GET" && url.pathname === "/readyz") {
        const readiness = await buildReadinessSnapshot({ runtimeConfig, firmware });
        sendJson(response, readiness.ok ? 200 : 503, readiness);
        return;
      }

      if (request.method === "GET" && url.pathname === "/v1/version") {
        sendJson(response, 200, buildVersionSnapshot(runtimeConfig));
        return;
      }

      if (request.method === "GET" && url.pathname === "/v1/system") {
        sendJson(response, 200, await buildSystemSnapshot({
          runtimeConfig,
          store,
          firmware,
          engine,
          cache: gatewayStateCache,
          firmwareOptions: stateFirmwareOptions
        }));
        return;
      }

      if (request.method === "GET" && url.pathname === "/v1/bedjets") {
        const gatewayState = await getSynchronizedGatewayState({ store, firmware, cache: gatewayStateCache, firmwareOptions: stateFirmwareOptions });
        sendJson(response, 200, { pairings: store.getPairings(), gatewayState });
        return;
      }

      const bedjetReadMatch = url.pathname.match(/^\/v1\/bedjets\/(left|right)$/);
      if (request.method === "GET" && bedjetReadMatch) {
        const [, side] = bedjetReadMatch;
        const gatewayState = await getSynchronizedGatewayState({ store, firmware, cache: gatewayStateCache, firmwareOptions: stateFirmwareOptions });
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
        sendJson(response, 200, await firmware.scan(stateFirmwareOptions));
        return;
      }

      const bedjetMatch = url.pathname.match(/^\/v1\/bedjets\/(left|right)\/(pair|verify|forget|release-ble|command)$/);
      if (bedjetMatch) {
        const [, side, action] = bedjetMatch;
        assertSide(side);

        if (action === "pair") {
          const body = await parseBody(request);
          const result = await firmware.pair(side, body, firmwareOptions);
          store.savePairing(side, result.pairing);
          sendJson(response, 200, result);
          return;
        }

        if (action === "verify") {
          const result = await firmware.verify(side, firmwareOptions);
          if (result.pairing) {
            store.savePairing(side, result.pairing);
          }
          sendJson(response, 200, result);
          return;
        }

        if (action === "forget") {
          const result = await firmware.forget(side, firmwareOptions);
          store.clearPairing(side);
          await engine.stopSide(side, "forgotten");
          sendJson(response, 200, result);
          return;
        }

        if (action === "release-ble") {
          sendJson(response, 200, await firmware.releaseBle(side, firmwareOptions));
          return;
        }

        if (action === "command") {
          const body = await parseBody(request);
          const result = await firmware.sendCommand(side, body, firmwareOptions);
          store.logCommand(side, "manual-command", body, result, true);
          sendJson(response, 200, result);
          return;
        }
      }

      if (request.method === "POST" && url.pathname === "/v1/system/release-ble") {
        sendJson(response, 200, await firmware.releaseAll(firmwareOptions));
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
      let statusCode = Number.isInteger(error.status) ? error.status : 500;
      if (error.name === "AbortError" || error.message === "Firmware request timed out") {
        statusCode = 504;
      } else if (statusCode === 500 && (error.cause || error.name === "TypeError")) {
        statusCode = 502;
      }
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
if (process.argv[1] && path.resolve(process.argv[1]) === currentFile) {
  const app = createBridgeServer();
  app.start().catch((error) => {
    defaultLogger.error("Failed to start bridge", { error: error.message });
    process.exitCode = 1;
  });
}
