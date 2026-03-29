const format = (level, message, meta) => {
  const base = `[${new Date().toISOString()}] ${level.toUpperCase()} ${message}`;
  if (!meta) {
    return base;
  }
  return `${base} ${JSON.stringify(meta)}`;
};

export const logger = {
  info(message, meta) {
    console.log(format("info", message, meta));
  },
  warn(message, meta) {
    console.warn(format("warn", message, meta));
  },
  error(message, meta) {
    console.error(format("error", message, meta));
  }
};

