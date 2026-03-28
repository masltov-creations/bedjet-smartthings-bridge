import crypto from "node:crypto";

const SIMULATED_DEVICES = [
  { deviceId: "bedjet-3-left-demo", displayName: "BedJet 3 Left Demo", rssi: -43 },
  { deviceId: "bedjet-3-right-demo", displayName: "BedJet 3 Right Demo", rssi: -47 }
];

const defaultSideState = () => ({
  paired: null,
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
    this.state.sides[side].paired = {
      side,
      deviceId: candidate.deviceId,
      displayName: candidate.displayName,
      pairedAt: new Date().toISOString()
    };
    this.state.sides[side].status.bleReleased = false;
    this.logger.info("Simulated pairing completed", { side, candidate });
    return { ok: true, pairing: structuredClone(this.state.sides[side].paired) };
  }

  async verify(side) {
    await sleep(50);
    return {
      ok: Boolean(this.state.sides[side].paired),
      side,
      pairing: structuredClone(this.state.sides[side].paired),
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
      pairing: structuredClone(sideState.paired),
      status: structuredClone(sideState.status)
    };
  }
}

class HttpFirmwareTransport {
  constructor(baseUrl, { authToken, gatewayId, sharedSecret }) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.authToken = authToken;
    this.gatewayId = gatewayId;
    this.sharedSecret = sharedSecret;
  }

  async getState() {
    return this.#request("GET", "/api/v1/state");
  }

  async getClaimStatus() {
    return this.#request("GET", "/api/v1/claim/status");
  }

  async claimGateway(payload) {
    return this.#request("POST", "/api/v1/claim", payload);
  }

  async scan() {
    return this.#request("GET", "/api/v1/scan");
  }

  async pair(side, candidate) {
    return this.#request("POST", `/api/v1/pair/${side}`, candidate);
  }

  async verify(side) {
    return this.#request("POST", `/api/v1/verify/${side}`, {});
  }

  async forget(side) {
    return this.#request("POST", `/api/v1/forget/${side}`, {});
  }

  async releaseBle(side) {
    return this.#request("POST", `/api/v1/release/${side}`, {});
  }

  async releaseAll() {
    return this.#request("POST", "/api/v1/release-all", {});
  }

  async sendCommand(side, command) {
    return this.#request("POST", `/api/v1/command/${side}`, command);
  }

  async #request(method, pathname, body) {
    const headers = { Accept: "application/json" };
    let payload = "";

    if (body !== undefined) {
      payload = JSON.stringify(body);
      headers["Content-Type"] = "application/json";
    }

    if (this.authToken) {
      headers.Authorization = `Bearer ${this.authToken}`;
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

    const response = await fetch(`${this.baseUrl}${pathname}`, {
      method,
      headers,
      body: payload || undefined
    });

    const text = await response.text();
    const data = text ? JSON.parse(text) : {};
    if (!response.ok) {
      throw new FirmwareRequestError(data.error || `Firmware request failed: ${response.status}`, response.status);
    }
    return data;
  }
}

export class FirmwareClient {
  constructor({ simulateFirmware, firmwareApiBaseUrl, firmwareAuthToken, firmwareGatewayId, firmwareSharedSecret, logger }) {
    this.transport = simulateFirmware
      ? new SimulatedFirmwareTransport(logger)
      : new HttpFirmwareTransport(firmwareApiBaseUrl, {
          authToken: firmwareAuthToken,
          gatewayId: firmwareGatewayId,
          sharedSecret: firmwareSharedSecret
        });
  }

  getState() {
    return this.transport.getState();
  }

  getClaimStatus() {
    return this.transport.getClaimStatus();
  }

  claimGateway(payload) {
    return this.transport.claimGateway(payload);
  }

  scan() {
    return this.transport.scan();
  }

  pair(side, candidate) {
    return this.transport.pair(side, candidate);
  }

  verify(side) {
    return this.transport.verify(side);
  }

  forget(side) {
    return this.transport.forget(side);
  }

  releaseBle(side) {
    return this.transport.releaseBle(side);
  }

  releaseAll() {
    return this.transport.releaseAll();
  }

  sendCommand(side, command) {
    return this.transport.sendCommand(side, command);
  }
}
