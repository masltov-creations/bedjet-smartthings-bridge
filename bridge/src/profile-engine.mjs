const runKey = (side) => `run:${side}`;

const asLocalParts = (date, timezone) => {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  });

  const parts = Object.fromEntries(formatter.formatToParts(date).map((part) => [part.type, part.value]));
  const weekdayMap = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

  return {
    weekday: weekdayMap[parts.weekday],
    year: Number(parts.year),
    month: Number(parts.month),
    day: Number(parts.day),
    hour: Number(parts.hour),
    minute: Number(parts.minute),
    localDate: `${parts.year}-${parts.month}-${parts.day}`
  };
};

export class ProfileEngine {
  constructor({ store, firmware, logger, timezone, schedulerIntervalMs }) {
    this.store = store;
    this.firmware = firmware;
    this.logger = logger;
    this.timezone = timezone;
    this.schedulerIntervalMs = schedulerIntervalMs;
    this.timers = new Map();
    this.scheduler = null;
  }

  #cancelTimersForSide(side, { exceptKey } = {}) {
    for (const [key, timer] of this.timers.entries()) {
      if (!key.startsWith(runKey(side))) {
        continue;
      }
      if (exceptKey && key === exceptKey) {
        continue;
      }
      clearTimeout(timer);
      this.timers.delete(key);
    }
  }

  #currentRunMatches(side, runId) {
    const run = this.store.getRun(side);
    return Boolean(run && run.status === "running" && run.runId === runId);
  }

  start() {
    this.store.interruptActiveRuns();
    this.scheduler = setInterval(() => {
      this.evaluateSchedules().catch((error) => {
        this.logger.error("Schedule evaluation failed", { error: error.message });
      });
    }, this.schedulerIntervalMs);
    this.scheduler.unref?.();
  }

  stop() {
    if (this.scheduler) {
      clearInterval(this.scheduler);
    }
    for (const timer of this.timers.values()) {
      clearTimeout(timer);
    }
    this.timers.clear();
  }

  listRuns() {
    return this.store.listRuns();
  }

  async startProfile(profileId, launchedBy = "manual") {
    const profile = this.store.getProfile(profileId);
    if (!profile) {
      throw new Error(`Unknown profile: ${profileId}`);
    }

    await this.stopSide(profile.side, "replaced");

    const startedAt = new Date();
    const runId = `${startedAt.getTime()}-${Math.random().toString(16).slice(2)}`;
    const run = {
      side: profile.side,
      profileId: profile.id,
      runId,
      status: "running",
      launchedBy,
      startedAt: startedAt.toISOString(),
      stepsTotal: profile.steps.length,
      lastExecutedStepIndex: -1
    };

    this.store.saveRun(profile.side, run);

    if (profile.steps.length === 0) {
      this.store.saveRun(profile.side, {
        ...run,
        status: "completed",
        completedAt: new Date().toISOString(),
        lastExecutedStepIndex: -1
      });
      return this.store.getRun(profile.side);
    }

    profile.steps.forEach((step, index) => {
      const timeoutMs = Math.max(0, step.offsetMinutes * 60_000);
      const timerKey = `${runKey(profile.side)}:${index}`;
      const timer = setTimeout(async () => {
        this.timers.delete(timerKey);

        if (!this.#currentRunMatches(profile.side, runId)) {
          return;
        }

        try {
          const response = await this.firmware.sendCommand(profile.side, step.command);
          this.store.logCommand(profile.side, "profile-step", step.command, response, true);
          if (!this.#currentRunMatches(profile.side, runId)) {
            return;
          }

          const current = this.store.getRun(profile.side);
          const nextStatus = index === profile.steps.length - 1 ? "completed" : "running";
          this.store.saveRun(profile.side, {
            ...current,
            status: nextStatus,
            lastExecutedStepIndex: index,
            lastStepExecutedAt: new Date().toISOString(),
            completedAt: nextStatus === "completed" ? new Date().toISOString() : current.completedAt
          });

          if (nextStatus === "completed") {
            this.#cancelTimersForSide(profile.side);
          }
        } catch (error) {
          this.store.logCommand(profile.side, "profile-step", step.command, { error: error.message }, false);

          if (!this.#currentRunMatches(profile.side, runId)) {
            return;
          }

          const current = this.store.getRun(profile.side);
          this.store.saveRun(profile.side, {
            ...current,
            status: "failed",
            lastExecutedStepIndex: index,
            lastError: error.message,
            failedAt: new Date().toISOString()
          });
          this.#cancelTimersForSide(profile.side);
        }
      }, timeoutMs);

      this.timers.set(timerKey, timer);
    });

    return this.store.getRun(profile.side);
  }

  async stopProfile(profileId, reason = "manual-stop") {
    const profile = this.store.getProfile(profileId);
    if (!profile) {
      throw new Error(`Unknown profile: ${profileId}`);
    }
    return this.stopSide(profile.side, reason);
  }

  async stopSide(side, reason = "manual-stop") {
    const run = this.store.getRun(side);
    this.#cancelTimersForSide(side);

    if (!run) {
      return null;
    }

    this.store.saveRun(side, {
      ...run,
      status: "stopped",
      stoppedAt: new Date().toISOString(),
      stopReason: reason
    });
    return this.store.getRun(side);
  }

  async evaluateSchedules(now = new Date()) {
    const local = asLocalParts(now, this.timezone);
    const profiles = this.store.listProfiles().filter((profile) => profile.enabled && profile.schedule?.enabled);

    for (const profile of profiles) {
      const [scheduleHour, scheduleMinute] = String(profile.schedule.localTime || "")
        .split(":")
        .map((part) => Number.parseInt(part, 10));

      const days = Array.isArray(profile.schedule.daysOfWeek) ? profile.schedule.daysOfWeek : [];
      const alreadyTriggered = profile.metadata?.lastTriggeredLocalDate === local.localDate;

      if (
        Number.isInteger(scheduleHour) &&
        Number.isInteger(scheduleMinute) &&
        !alreadyTriggered &&
        days.includes(local.weekday) &&
        local.hour === scheduleHour &&
        local.minute === scheduleMinute
      ) {
        await this.startProfile(profile.id, "schedule");
        this.store.markProfileTriggered(profile.id, local.localDate);
      }
    }
  }
}
