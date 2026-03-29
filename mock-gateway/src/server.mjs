import crypto from "node:crypto";
import http from "node:http";
import path from "node:path";
import { pathToFileURL } from "node:url";

const SIMULATED_DEVICES = [
  { deviceId: "bedjet-3-left-demo", displayName: "BedJet 3 Left Demo", rssi: -43 },
  { deviceId: "bedjet-3-right-demo", displayName: "BedJet 3 Right Demo", rssi: -47 }
];

const defaultConfig = Object.freeze({
  host: process.env.HOST || "127.0.0.1",
  port: Number.parseInt(process.env.PORT || "8789", 10),
  hostname: process.env.MOCK_HOSTNAME || "bedjet-gateway-mock",
  configuredSsid: process.env.MOCK_SSID || "MockWiFi"
});

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

const makeState = (config) => ({
  network: {
    mode: "station",
    hostname: config.hostname,
    configuredSsid: config.configuredSsid,
    stationConnected: true,
    stationIp: "127.0.0.1",
    setupApActive: false,
    setupApSsid: "",
    setupApIp: "",
    mdnsUrl: `http://${config.hostname}.local`
  },
  claim: {
    claimable: true,
    claimed: false,
    gatewayId: "",
    sharedSecret: "",
    claimedAt: ""
  },
  recentNonces: [],
  sides: {
    left: defaultSideState(),
    right: defaultSideState()
  },
  devices: [...SIMULATED_DEVICES]
});

const json = (response, statusCode, payload) => {
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  response.end(JSON.stringify(payload, null, 2));
};

const parseBody = async (request) => {
  const chunks = [];
  for await (const chunk of request) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
};

export const createMockGatewayServer = (options = {}) => {
  const config = { ...defaultConfig, ...options };
  const state = makeState(config);

  const getSignedHeaders = (request) => ({
    gatewayId: request.headers["x-gateway-id"] || "",
    timestamp: request.headers["x-timestamp"] || "",
    nonce: request.headers["x-nonce"] || "",
    signature: request.headers["x-signature"] || ""
  });

  const verifySignature = ({ method, pathname, body, request }) => {
    if (!state.claim.claimed || !state.claim.sharedSecret) {
      return { ok: false, statusCode: 503, error: "gateway not claimed" };
    }

    const headers = getSignedHeaders(request);
    if (!headers.gatewayId || !headers.timestamp || !headers.nonce || !headers.signature) {
      return { ok: false, statusCode: 401, error: "missing auth headers" };
    }
    if (headers.gatewayId !== state.claim.gatewayId) {
      return { ok: false, statusCode: 403, error: "gateway id mismatch" };
    }

    const timestampValue = Number.parseInt(headers.timestamp, 10);
    if (!Number.isFinite(timestampValue) || Math.abs(Date.now() - timestampValue) > 30_000) {
      return { ok: false, statusCode: 401, error: "timestamp skew too large" };
    }
    if (headers.nonce.length < 8 || state.recentNonces.includes(headers.nonce)) {
      return { ok: false, statusCode: 409, error: "nonce rejected" };
    }

    const message = [method.toUpperCase(), pathname, body, headers.timestamp, headers.nonce].join("\n");
    const expected = crypto.createHmac("sha256", state.claim.sharedSecret).update(message).digest("hex");
    if (expected !== String(headers.signature).toLowerCase()) {
      return { ok: false, statusCode: 403, error: "invalid signature" };
    }

    state.recentNonces.push(headers.nonce);
    if (state.recentNonces.length > 8) {
      state.recentNonces.shift();
    }
    return { ok: true };
  };

  const withAuth = async (request, response, pathname, handler) => {
    const body = await parseBody(request);
    const auth = verifySignature({ method: request.method, pathname, body, request });
    if (!auth.ok) {
      json(response, auth.statusCode, { error: auth.error });
      return;
    }
    await handler(body);
  };

  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);

    if (request.method === "GET" && url.pathname === "/healthz") {
      json(response, 200, {
        ok: true,
        service: "bedjet-gateway-mock",
        simulatedBackend: true,
        claimed: state.claim.claimed,
        network: state.network
      });
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/v1/provision/status") {
      json(response, 200, { ok: true, network: state.network, claim: { ...state.claim, sharedSecret: undefined } });
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/v1/provision/wifi") {
      const body = JSON.parse((await parseBody(request)) || "{}");
      state.network.configuredSsid = body.ssid || state.network.configuredSsid;
      state.network.hostname = body.hostname || state.network.hostname;
      state.network.mdnsUrl = `http://${state.network.hostname}.local`;
      json(response, 200, { ok: true, saved: true, restarting: false, hostname: state.network.hostname, ssid: state.network.configuredSsid });
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/v1/claim/status") {
      json(response, 200, {
        claimable: !state.claim.claimed,
        claimed: state.claim.claimed,
        gatewayId: state.claim.gatewayId,
        claimedAt: state.claim.claimedAt
      });
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/v1/claim") {
      const body = JSON.parse((await parseBody(request)) || "{}");
      if (state.claim.claimed) {
        json(response, 409, { error: "gateway already claimed" });
        return;
      }
      if (!body.gatewayId || !body.sharedSecret || String(body.sharedSecret).length < 16) {
        json(response, 400, { error: "gatewayId or sharedSecret too short" });
        return;
      }
      state.claim = {
        claimable: false,
        claimed: true,
        gatewayId: body.gatewayId,
        sharedSecret: body.sharedSecret,
        claimedAt: new Date().toISOString()
      };
      json(response, 200, {
        ok: true,
        claimable: false,
        claimed: true,
        gatewayId: state.claim.gatewayId,
        claimedAt: state.claim.claimedAt
      });
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/v1/state") {
      await withAuth(request, response, url.pathname, async () => {
        json(response, 200, {
          claim: {
            claimed: state.claim.claimed,
            gatewayId: state.claim.gatewayId
          },
          network: state.network,
          sides: state.sides
        });
      });
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/v1/scan") {
      await withAuth(request, response, url.pathname, async () => {
        json(response, 200, { devices: state.devices });
      });
      return;
    }

    const actionMatch = url.pathname.match(/^\/api\/v1\/(pair|verify|forget|release|command)\/(left|right)$/);
    if (request.method === "POST" && actionMatch) {
      const [, action, side] = actionMatch;
      await withAuth(request, response, url.pathname, async (rawBody) => {
        const body = rawBody ? JSON.parse(rawBody) : {};
        const sideState = state.sides[side];

        if (action === "pair") {
          sideState.paired = {
            side,
            deviceId: body.deviceId || `bedjet-3-${side}-demo`,
            displayName: body.displayName || `BedJet 3 ${side[0].toUpperCase()}${side.slice(1)} Demo`,
            pairedAt: new Date().toISOString()
          };
          sideState.status.bleReleased = false;
          json(response, 200, { ok: true, pairing: sideState.paired });
          return;
        }

        if (action === "verify") {
          json(response, 200, {
            ok: Boolean(sideState.paired),
            side,
            pairing: sideState.paired,
            status: sideState.status
          });
          return;
        }

        if (action === "forget") {
          state.sides[side] = defaultSideState();
          json(response, 200, { ok: true, side });
          return;
        }

        if (action === "release") {
          sideState.status.bleReleased = true;
          json(response, 200, { ok: true, side, bleReleased: true });
          return;
        }

        if (!sideState.paired) {
          json(response, 409, { error: "side not paired" });
          return;
        }

        sideState.status = {
          ...sideState.status,
          ...body,
          bleReleased: false,
          currentTemperatureC: body.targetTemperatureC ?? sideState.status.currentTemperatureC
        };
        json(response, 200, { ok: true, side, pairing: sideState.paired, status: sideState.status });
      });
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/v1/release-all") {
      await withAuth(request, response, url.pathname, async () => {
        for (const side of ["left", "right"]) {
          state.sides[side].status.bleReleased = true;
        }
        json(response, 200, { ok: true });
      });
      return;
    }

    json(response, 404, { error: "not found" });
  });

  return { server, state, config };
};

const isDirectRun = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isDirectRun) {
  const { server, config } = createMockGatewayServer();
  server.listen(config.port, config.host, () => {
    console.log(`mock-gateway listening on http://${config.host}:${config.port}`);
  });
}
