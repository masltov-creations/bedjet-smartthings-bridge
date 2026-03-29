import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const bridgeRoot = path.resolve(__dirname, "..");

const parseBoolean = (value, defaultValue) => {
  if (value === undefined || value === "") {
    return defaultValue;
  }
  return ["1", "true", "yes", "on"].includes(String(value).toLowerCase());
};

const parseInteger = (value, defaultValue) => {
  if (value === undefined || value === "") {
    return defaultValue;
  }

  const parsed = Number.parseInt(String(value), 10);
  if (Number.isNaN(parsed)) {
    throw new Error(`Invalid integer value: ${value}`);
  }
  return parsed;
};

const resolvePath = (value, fallback) => {
  const raw = value && value.trim().length > 0 ? value : fallback;
  return path.isAbsolute(raw) ? raw : path.resolve(bridgeRoot, raw);
};

export const config = Object.freeze({
  host: process.env.HOST || "0.0.0.0",
  port: parseInteger(process.env.PORT, 8787),
  timezone: process.env.TIMEZONE || "America/Los_Angeles",
  dataPath: resolvePath(process.env.DATA_PATH, "./data/bridge.sqlite"),
  firmwareApiBaseUrl: (process.env.FIRMWARE_API_BASE_URL || "http://bedjet-gateway.local").replace(/\/$/, ""),
  firmwareGatewayId: process.env.FIRMWARE_GATEWAY_ID || "bedjet-bridge",
  firmwareSharedSecret: process.env.FIRMWARE_SHARED_SECRET || "",
  firmwareAuthToken: process.env.FIRMWARE_AUTH_TOKEN || "",
  simulateFirmware: parseBoolean(process.env.SIMULATE_FIRMWARE, true),
  schedulerIntervalMs: parseInteger(process.env.SCHEDULER_INTERVAL_MS, 30_000)
});

fs.mkdirSync(path.dirname(config.dataPath), { recursive: true });
