const LEVELS = ["debug", "info", "warn", "error"] as const;
type Level = (typeof LEVELS)[number];

const envLevel = (process.env.KAPSIS_DASHBOARD_LOG_LEVEL ?? "info").toLowerCase() as Level;
const threshold = Math.max(0, LEVELS.indexOf(envLevel));

function emit(level: Level, msg: string, fields?: Record<string, unknown>): void {
  if (LEVELS.indexOf(level) < threshold) return;
  const ts = new Date().toISOString();
  const line = fields
    ? `${ts} ${level.toUpperCase()} ${msg} ${JSON.stringify(fields)}`
    : `${ts} ${level.toUpperCase()} ${msg}`;
  if (level === "error") console.error(line);
  else console.log(line);
}

export const log = {
  debug: (msg: string, fields?: Record<string, unknown>) => emit("debug", msg, fields),
  info: (msg: string, fields?: Record<string, unknown>) => emit("info", msg, fields),
  warn: (msg: string, fields?: Record<string, unknown>) => emit("warn", msg, fields),
  error: (msg: string, fields?: Record<string, unknown>) => emit("error", msg, fields),
};
