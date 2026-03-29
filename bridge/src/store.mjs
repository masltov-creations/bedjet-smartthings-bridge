import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const SIDES = new Set(["left", "right"]);

const defaultProfiles = [
  {
    id: "left-nightly-bio",
    name: "Left Nightly Bio",
    side: "left",
    enabled: 1,
    steps: [
      { offsetMinutes: 0, command: { power: "on", mode: "cool", fanStep: 10, targetTemperatureC: 24 } },
      { offsetMinutes: 90, command: { mode: "cool", fanStep: 7, targetTemperatureC: 23 } },
      { offsetMinutes: 240, command: { mode: "heat", fanStep: 4, targetTemperatureC: 28 } }
    ],
    schedule: { enabled: false, localTime: "22:30", daysOfWeek: [0, 1, 2, 3, 4, 5, 6] },
    metadata: { description: "Default left-side starter profile", lastTriggeredLocalDate: null }
  },
  {
    id: "right-nightly-bio",
    name: "Right Nightly Bio",
    side: "right",
    enabled: 1,
    steps: [
      { offsetMinutes: 0, command: { power: "on", mode: "cool", fanStep: 10, targetTemperatureC: 24 } },
      { offsetMinutes: 90, command: { mode: "cool", fanStep: 7, targetTemperatureC: 23 } },
      { offsetMinutes: 240, command: { mode: "heat", fanStep: 4, targetTemperatureC: 28 } }
    ],
    schedule: { enabled: false, localTime: "22:30", daysOfWeek: [0, 1, 2, 3, 4, 5, 6] },
    metadata: { description: "Default right-side starter profile", lastTriggeredLocalDate: null }
  }
];

const parseJson = (value, fallback = null) => {
  if (!value) {
    return fallback;
  }
  return JSON.parse(value);
};

const stringify = (value) => JSON.stringify(value ?? null);

export class BridgeStore {
  constructor(dbPath) {
    fs.mkdirSync(path.dirname(dbPath), { recursive: true });
    this.db = new DatabaseSync(dbPath);
    this.prepareSchema();
    this.seedDefaults();
  }

  prepareSchema() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS pairings (
        side TEXT PRIMARY KEY,
        pairing_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS profiles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        side TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        steps_json TEXT NOT NULL,
        schedule_json TEXT NOT NULL,
        metadata_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS runs (
        side TEXT PRIMARY KEY,
        profile_id TEXT NOT NULL,
        status TEXT NOT NULL,
        run_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS command_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at TEXT NOT NULL,
        side TEXT NOT NULL,
        action TEXT NOT NULL,
        request_json TEXT NOT NULL,
        response_json TEXT NOT NULL,
        ok INTEGER NOT NULL
      );
    `);
  }

  seedDefaults() {
    const existingCount = this.db.prepare("SELECT COUNT(*) AS count FROM profiles").get().count;
    if (existingCount > 0) {
      return;
    }

    const insert = this.db.prepare(`
      INSERT INTO profiles (id, name, side, enabled, steps_json, schedule_json, metadata_json, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    const now = new Date().toISOString();
    for (const profile of defaultProfiles) {
      insert.run(
        profile.id,
        profile.name,
        profile.side,
        profile.enabled,
        stringify(profile.steps),
        stringify(profile.schedule),
        stringify(profile.metadata),
        now
      );
    }
  }

  listProfiles() {
    const rows = this.db.prepare("SELECT * FROM profiles ORDER BY name").all();
    return rows.map((row) => this.#mapProfile(row));
  }

  getProfile(profileId) {
    const row = this.db.prepare("SELECT * FROM profiles WHERE id = ?").get(profileId);
    return row ? this.#mapProfile(row) : null;
  }

  saveProfile(profile) {
    if (!SIDES.has(profile.side)) {
      throw new Error(`Invalid profile side: ${profile.side}`);
    }

    const now = new Date().toISOString();
    this.db.prepare(`
      INSERT INTO profiles (id, name, side, enabled, steps_json, schedule_json, metadata_json, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        side = excluded.side,
        enabled = excluded.enabled,
        steps_json = excluded.steps_json,
        schedule_json = excluded.schedule_json,
        metadata_json = excluded.metadata_json,
        updated_at = excluded.updated_at
    `).run(
      profile.id,
      profile.name,
      profile.side,
      profile.enabled ? 1 : 0,
      stringify(profile.steps),
      stringify(profile.schedule),
      stringify(profile.metadata ?? {}),
      now
    );

    return this.getProfile(profile.id);
  }

  markProfileTriggered(profileId, localDate) {
    const profile = this.getProfile(profileId);
    if (!profile) {
      throw new Error(`Unknown profile: ${profileId}`);
    }
    profile.metadata = { ...(profile.metadata || {}), lastTriggeredLocalDate: localDate };
    return this.saveProfile(profile);
  }

  getPairings() {
    const rows = this.db.prepare("SELECT side, pairing_json, updated_at FROM pairings ORDER BY side").all();
    const result = { left: null, right: null };
    for (const row of rows) {
      result[row.side] = { ...parseJson(row.pairing_json), updatedAt: row.updated_at };
    }
    return result;
  }

  getPairing(side) {
    this.#assertSide(side);
    const row = this.db.prepare("SELECT side, pairing_json, updated_at FROM pairings WHERE side = ?").get(side);
    return row ? { ...parseJson(row.pairing_json), updatedAt: row.updated_at } : null;
  }

  savePairing(side, pairing) {
    this.#assertSide(side);
    const now = new Date().toISOString();
    this.db.prepare(`
      INSERT INTO pairings (side, pairing_json, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(side) DO UPDATE SET
        pairing_json = excluded.pairing_json,
        updated_at = excluded.updated_at
    `).run(side, stringify(pairing), now);
    return this.getPairing(side);
  }

  clearPairing(side) {
    this.#assertSide(side);
    this.db.prepare("DELETE FROM pairings WHERE side = ?").run(side);
  }

  listRuns() {
    const rows = this.db.prepare("SELECT * FROM runs ORDER BY side").all();
    return rows.map((row) => this.#mapRun(row));
  }

  getRun(side) {
    this.#assertSide(side);
    const row = this.db.prepare("SELECT * FROM runs WHERE side = ?").get(side);
    return row ? this.#mapRun(row) : null;
  }

  saveRun(side, run) {
    this.#assertSide(side);
    const now = new Date().toISOString();
    this.db.prepare(`
      INSERT INTO runs (side, profile_id, status, run_json, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(side) DO UPDATE SET
        profile_id = excluded.profile_id,
        status = excluded.status,
        run_json = excluded.run_json,
        updated_at = excluded.updated_at
    `).run(side, run.profileId, run.status, stringify(run), now);
    return this.getRun(side);
  }

  clearRun(side) {
    this.#assertSide(side);
    this.db.prepare("DELETE FROM runs WHERE side = ?").run(side);
  }

  interruptActiveRuns() {
    const rows = this.listRuns().filter((run) => run.status === "running");
    for (const run of rows) {
      this.saveRun(run.side, {
        ...run,
        status: "interrupted",
        interruptedAt: new Date().toISOString()
      });
    }
  }

  logCommand(side, action, request, response, ok) {
    this.#assertSide(side);
    this.db.prepare(`
      INSERT INTO command_log (created_at, side, action, request_json, response_json, ok)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(
      new Date().toISOString(),
      side,
      action,
      stringify(request),
      stringify(response),
      ok ? 1 : 0
    );
  }

  recentCommands(limit = 20) {
    return this.db.prepare(`
      SELECT * FROM command_log ORDER BY id DESC LIMIT ?
    `).all(limit).map((row) => ({
      id: row.id,
      createdAt: row.created_at,
      side: row.side,
      action: row.action,
      request: parseJson(row.request_json, {}),
      response: parseJson(row.response_json, {}),
      ok: row.ok === 1
    }));
  }

  close() {
    this.db.close();
  }

  #mapProfile(row) {
    return {
      id: row.id,
      name: row.name,
      side: row.side,
      enabled: row.enabled === 1,
      steps: parseJson(row.steps_json, []),
      schedule: parseJson(row.schedule_json, {}),
      metadata: parseJson(row.metadata_json, {}),
      updatedAt: row.updated_at
    };
  }

  #mapRun(row) {
    return {
      ...parseJson(row.run_json, {}),
      side: row.side,
      profileId: row.profile_id,
      status: row.status,
      updatedAt: row.updated_at
    };
  }

  #assertSide(side) {
    if (!SIDES.has(side)) {
      throw new Error(`Invalid side: ${side}`);
    }
  }
}

