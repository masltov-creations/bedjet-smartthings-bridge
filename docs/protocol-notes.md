# Protocol Contract

## Runtime Topology

1. SmartThings Hub -> Bridge over LAN HTTP.
2. Bridge -> Gateway over LAN HTTP.
3. Gateway -> BedJet devices over BLE.

## Bridge <-> Gateway Trust Model

The gateway accepts control only from a claimed bridge identity.

### Claim

1. Read `GET /api/v1/claim/status`.
2. If unclaimed, send `POST /api/v1/claim` with:
   - `gatewayId`
   - `sharedSecret`
3. Gateway stores claim metadata and enforces signed auth on protected routes.

### Signed Headers (protected routes)

- `X-Gateway-Id`
- `X-Timestamp`
- `X-Nonce`
- `X-Signature`

Signature format:

`HMAC_SHA256(sharedSecret, method + "\n" + path + "\n" + body + "\n" + timestamp + "\n" + nonce)`

Gateway rejects requests when claim/auth checks fail (missing headers, ID mismatch, timestamp skew, nonce replay, bad signature).

## Gateway API Surface

### Public

- `GET /healthz`
- `GET /api/v1/claim/status`
- `POST /api/v1/claim`

### Protected

- `GET /api/v1/state`
- `GET /api/v1/scan`
- `POST /api/v1/pair/{side}`
- `POST /api/v1/verify/{side}`
- `POST /api/v1/forget/{side}`
- `POST /api/v1/release/{side}`
- `POST /api/v1/release-all`
- `POST /api/v1/command/{side}`

Valid side values:

- `left`
- `right`
