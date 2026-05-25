import crypto from "node:crypto";

const SIMULATED_DEVICES = [
  { deviceId: "bedjet-3-left-demo", displayName: "BedJet 3 Left Demo", rssi: -43 },
  { deviceId: "bedjet-3-right-demo", displayName: "BedJet 3 Right Demo", rssi: -47 }
];

const defaultSideState = () => ({
  paired: false,
  deviceId: "",
  displayName: "",
  pairedAt: "",
  status: {
    power: "off",
    mode: "cool",
    fanStep: 8,
    targetTemperatureC: 24,
    currentTemperatureC: 23,
    bleReleased: false
  }
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const buildPairing = (sideState, side) => {
  if (!sideState?.paired || !sideState.deviceId) {
    return null;
  }

  return {
    side,
    deviceId: sideState.deviceId,
    displayName: sideState.displayName,
    pairedAt: sideState.pairedAt || null
  };
};

class FirmwareRequestError extends Error {
  constructor(message, status) {
    super(message);
    this.name = "FirmwareRequestError";
    this.status = status;
  }
}

class SimulatedFirmwareTransport {
  constructor(logger) {
    this.logger = logger;
    this.state = {
      claim: {
        gatewayId: "",
        claimed: false,
        claimable: true
      },
      availableDevices: [...SIMULATED_DEVICES],
      sides: {
        left: defaultSideState(),
        right: defaultSideState()
      }
    };
  }

  async getState() {
    return structuredClone(this.state);
  }

  async getClaimStatus() {
    return structuredClone(this.state.claim);
  }

  async claimGateway({ gatewayId }) {
    this.state.claim = {
      gatewayId,
      claimed: true,
      claimable: false
    };
    return { ok: true, gatewayId, claimable: false, claimed: true };
  }

  async scan() {
    return { devices: structuredClone(this.state.availableDevices) };
  }

  async pair(side, candidate) {
    await sleep(100);
    this.state.sides[side].paired = true;
    this.state.sides[side].deviceId = candidate.deviceId;
    this.state.sides[side].displayName = candidate.displayName;
    this.state.sides[side].pairedAt = new Date().toISOString();
    this.state.sides[side].status.bleReleased = false;
    this.logger.info("Simulated pairing completed", { side, candidate });
    return { ok: true, pairing: buildPairing(this.state.sides[side], side) };
  }

  async verify(side) {
    await sleep(50);
    return {
      ok: Boolean(this.state.sides[side].paired),
      side,
      pairing: buildPairing(this.state.sides[side], side),
      status: structuredClone(this.state.sides[side].status)
    };
  }

  async forget(side) {
    this.state.sides[side] = defaultSideState();
    return { ok: true, side };
  }

  async releaseBle(side) {
    this.state.sides[side].status.bleReleased = true;
    return { ok: true, side, bleReleased: true };
  }

  async releaseAll() {
    for (const side of ["left", "right"]) {
      this.state.sides[side].status.bleReleased = true;
    }
    return { ok: true };
  }

  async sendCommand(side, command) {
    const sideState = this.state.sides[side];
    if (!sideState.paired) {
      throw new Error(`Side ${side} is not paired`);
    }

    sideState.status = {
      ...sideState.status,
      ...command,
      bleReleased: false,
      currentTemperatureC: command.targetTemperatureC ?? sideState.status.currentTemperatureC
    };

    return {
      ok: true,
      confirmed: true,
      side,
      pairing: buildPairing(sideState, side),
      status: structuredClone(sideState.status)
    };
  }
}

class HttpFirmwareTransport {
  // The ESP32 gateway handles one TCP request at a time.  Serializing here
  // prevents concurrent bridge requests (e.g. left-side command + right-side
  // poll) from racing each other, which causes timeout-driven retries and
  // cascading multi-second delays.
  #requestQueue = Promise.resolve();

  constructor(baseUrl, { gatewayId, sharedSecret, timeoutMs, retries }) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.gatewayId = gatewayId;
    this.sharedSecret = sharedSecret;
    this.timeoutMs = timeoutMs;
    this.retries = retries;
  }

  async getState(options = {}) {
    return this.#request("GET", "/api/v1/state", undefined, { ...options, retries: options.retries ?? this.retries });
  }

  async getClaimStatus(options = {}) {
    return this.#request("GET", "/api/v1/claim/status", undefined, { ...options, retries: options.retries ?? this.retries });
  }

  async claimGateway(payload, options = {}) {
    return this.#request("POST", "/api/v1/claim", payload, { ...options, retries: 0 });
  }

  async scan(options = {}) {
    return this.#request("GET", "/api/v1/scan", undefined, { ...options, retries: options.retries ?? this.retries });
  }

  async pair(side, candidate, options = {}) {
    return this.#request("POST", `/api/v1/pair/${side}`, candidate, { ...options, retries: 0 });
  }

  async verify(side, options = {}) {
    return this.#request("POST", `/api/v1/verify/${side}`, {}, { ...options, retries: options.retries ?? this.retries });
  }

  async forget(side, options = {}) {
    return this.#request("POST", `/api/v1/forget/${side}`, {}, { ...options, retries: 0 });
  }

  async releaseBle(side, options = {}) {
    return this.#request("POST", `/api/v1/release/${side}`, {}, { ...options, retries: 0 });
  }

  async releaseAll(options = {}) {
    return this.#request("POST", "/api/v1/release-all", {}, { ...options, retries: 0 });
  }

  async sendCommand(side, command, options = {}) {
    return this.#request("POST", `/api/v1/command/${side}`, command, { ...options, retries: 0 });
  }

  async #request(method, pathname, body, options = {}) {
    // Enqueue behind any in-flight gateway request so the ESP32 never receives
    // concurrent TCP connections from this bridge instance.
    let resolve, reject;
    const result = new Promise((res, rej) => { resolve = res; reject = rej; });
    this.#requestQueue = this.#requestQueue
      .catch(() => {}) // previous request failure must not break the chain
      .then(async () => {
        try { resolve(await this.#doRequest(method, pathname, body, options)); }
        catch (err) { reject(err); }
      });
    return result;
  }

  async #doRequest(method, pathname, body, options = {}) {
    const timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : this.timeoutMs;
    const retries = Number.isInteger(options.retries) ? Math.max(0, options.retries) : 0;
    const baseDelayMs = Number.isFinite(options.retryBaseDelayMs) ? options.retryBaseDelayMs : 200;
    const externalSignal = options.signal;

    let payload = "";
    if (body !== undefined) {
      payload = JSON.stringify(body);
    }

    const retryableStatusCodes = new Set([408, 425, 429, 500, 502, 503, 504]);
    const isRetryableError = (error) => {
      if (!error) {
        return false;
      }
      if (error.name === "AbortError") {
        return false;
      }
      if (error instanceof FirmwareRequestError && Number.isInteger(error.status)) {
        return retryableStatusCodes.has(error.status);
      }
      return true;
    };

    const buildHeaders = () => {
      const headers = { Accept: "application/json" };
      if (body !== undefined) {
        headers["Content-Type"] = "application/json";
      }

      if (this.sharedSecret) {
        const timestamp = String(Date.now());
        const nonce = crypto.randomBytes(12).toString("hex");
        const payloadToSign = [method.toUpperCase(), pathname, payload, timestamp, nonce].join("\n");
        const signature = crypto.createHmac("sha256", this.sharedSecret).update(payloadToSign).digest("hex");
        headers["X-Gateway-Id"] = this.gatewayId;
        headers["X-Timestamp"] = timestamp;
        headers["X-Nonce"] = nonce;
        headers["X-Signature"] = signature;
      }

      return headers;
    };

    const makeAbortSignal = () => {
      if (!timeoutMs && !externalSignal) {
        return { signal: undefined, cleanup: () => {} };
      }

      const controller = new AbortController();
      const timers = [];
      let removeExternalListener = null;

      if (timeoutMs) {
        const timer = setTimeout(() => controller.abort(new Error("Firmware request timed out")), timeoutMs);
        timer.unref?.();
        timers.push(timer);
      }

      if (externalSignal) {
        if (externalSignal.aborted) {
          controller.abort(externalSignal.reason);
        } else {
          const onAbort = () => {
            controller.abort(externalSignal.reason);
          };
          externalSignal.addEventListener("abort", onAbort, { once: true });
          removeExternalListener = () => externalSignal.removeEventListener("abort", onAbort);
        }
      }

      return {
        signal: controller.signal,
        cleanup: () => {
          for (const timer of timers) {
            clearTimeout(timer);
          }
          removeExternalListener?.();
        }
      };
    };

    const parseJsonResponse = (text, status) => {
      if (!text) {
        return {};
      }
      try {
        return JSON.parse(text);
      } catch {
        throw new FirmwareRequestError(`Firmware returned invalid JSON (HTTP ${status})`, 502);
      }
    };

    for (let attempt = 0; attempt <= retries; attempt += 1) {
      const { signal, cleanup } = makeAbortSignal();
      try {
        const response = await fetch(`${this.baseUrl}${pathname}`, {
          method,
          headers: buildHeaders(),
          body: payload || undefined,
          signal
        });

        const text = await response.text();
        const data = parseJsonResponse(text, response.status);

        if (!response.ok) {
          throw new FirmwareRequestError(data.error || `Firmware request failed: ${response.status}`, response.status);
        }

        return data;
      } catch (error) {
        if (attempt >= retries || method.toUpperCase() !== "GET" || !isRetryableError(error)) {
          throw error;
        }

        const delayMs = baseDelayMs * 2 ** attempt + Math.floor(Math.random() * 75);
        await sleep(delayMs);
      } finally {
        cleanup();
      }
    }

    throw new FirmwareRequestError("Firmware request failed after retries", 503);
  }
}

export class FirmwareClient {
  constructor({
    simulateFirmware,
    firmwareApiBaseUrl,
    firmwareGatewayId,
    firmwareSharedSecret,
    firmwareRequestTimeoutMs,
    firmwareRequestRetries,
    logger
  }) {
    this.transport = simulateFirmware
      ? new SimulatedFirmwareTransport(logger)
      : new HttpFirmwareTransport(firmwareApiBaseUrl, {
          gatewayId: firmwareGatewayId,
          sharedSecret: firmwareSharedSecret,
          timeoutMs: firmwareRequestTimeoutMs,
          retries: firmwareRequestRetries
        });
  }

  getState(options) {
    return this.transport.getState(options);
  }

  getClaimStatus(options) {
    return this.transport.getClaimStatus(options);
  }

  claimGateway(payload, options) {
    return this.transport.claimGateway(payload, options);
  }

  scan(options) {
    return this.transport.scan(options);
  }

  pair(side, candidate, options) {
    return this.transport.pair(side, candidate, options);
  }

  verify(side, options) {
    return this.transport.verify(side, options);
  }

  forget(side, options) {
    return this.transport.forget(side, options);
  }

  releaseBle(side, options) {
    return this.transport.releaseBle(side, options);
  }

  releaseAll(options) {
    return this.transport.releaseAll(options);
  }

  sendCommand(side, command, options) {
    return this.transport.sendCommand(side, command, options);
  }
}
