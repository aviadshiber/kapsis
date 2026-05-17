import { resolve } from "node:path";
import { parseArgs } from "node:util";
import { startServer } from "./server";
import { generateToken } from "./auth";
import { defaultKapsisHome, paths, DEFAULT_HOST, DEFAULT_PORT, type DashboardConfig } from "./config";
import { StatusStore } from "./store/status";
import { AuditStore } from "./store/audit";
import { LogStore } from "./store/logs";
import { ConversationStore } from "./store/conversations";
import { DiskUsageStore } from "./store/disk";
import { DashboardAuditWriter } from "./control/audit-writer";
import { SseBroker } from "./sse";
import { log } from "./logger";

const VERSION = "0.1.0";

interface Args {
  port: number;
  host: string;
  kapsisHome: string;
  readOnly: boolean;
  open: boolean;
  token: string | null;
  uiDist: string | null;
  cleanupScript: string;
}

function parseCliArgs(argv: string[]): Args {
  const { values } = parseArgs({
    args: argv,
    options: {
      port: { type: "string", default: String(DEFAULT_PORT) },
      host: { type: "string", default: DEFAULT_HOST },
      "kapsis-home": { type: "string" },
      "read-only": { type: "boolean", default: false },
      open: { type: "boolean", default: false },
      token: { type: "string" },
      "ui-dist": { type: "string" },
      "cleanup-script": { type: "string" },
      help: { type: "boolean", short: "h", default: false },
      version: { type: "boolean", short: "v", default: false },
    },
    strict: true,
  });

  if (values.help) {
    printHelp();
    process.exit(0);
  }
  if (values.version) {
    console.log(VERSION);
    process.exit(0);
  }

  const home = values["kapsis-home"] ?? defaultKapsisHome();
  return {
    port: Number(values.port),
    host: values.host as string,
    kapsisHome: resolve(home),
    readOnly: Boolean(values["read-only"]),
    open: Boolean(values.open),
    token: (values.token as string | undefined) ?? null,
    uiDist: (values["ui-dist"] as string | undefined) ?? null,
    cleanupScript:
      (values["cleanup-script"] as string | undefined) ??
      resolve(process.env.KAPSIS_HOME_DIR ?? `${process.env.HOME}/git/kapsis`, "scripts/kapsis-cleanup.sh"),
  };
}

function printHelp(): void {
  console.log(`kapsis-dashboard ${VERSION}

USAGE
  kapsis-dashboard [flags]

FLAGS
  --port <n>            HTTP port (default ${DEFAULT_PORT})
  --host <addr>         Bind address (default ${DEFAULT_HOST})
  --kapsis-home <path>  Root of ~/.kapsis (default $KAPSIS_HOME or ~/.kapsis)
  --read-only           Disable destructive endpoints
  --open                Open the dashboard URL in a browser at startup
  --token <s>           Use a fixed bearer token instead of a random one
  --ui-dist <path>      Serve a Vite-built UI bundle from this dir (dev override)
  --cleanup-script <p>  Path to scripts/kapsis-cleanup.sh
  -v, --version         Print version and exit
  -h, --help            Show this help
`);
}

async function openBrowser(url: string): Promise<void> {
  const platform = process.platform;
  const argv = platform === "darwin" ? ["open", url]
    : platform === "win32" ? ["cmd", "/c", "start", url]
    : ["xdg-open", url];
  try {
    Bun.spawn(argv, { stdout: "ignore", stderr: "ignore" });
  } catch (e) {
    log.warn("could not open browser", { err: String(e) });
  }
}

async function main(): Promise<void> {
  const args = parseCliArgs(Bun.argv.slice(2));
  const p = paths(args.kapsisHome);
  const token = args.token ?? generateToken();

  const config: DashboardConfig = {
    host: args.host,
    port: args.port,
    kapsisHome: args.kapsisHome,
    readOnly: args.readOnly,
    open: args.open,
    token,
    uiDistDir: args.uiDist,
  };

  const status = new StatusStore(p.status);
  await status.init();
  const audit = new AuditStore(p.audit);
  const logsStore = new LogStore(p.logs);
  const conv = new ConversationStore(p.conversations);
  const disk = new DiskUsageStore(p);
  const dashAudit = new DashboardAuditWriter(p.dashboardAudit);
  await dashAudit.init();
  const sse = new SseBroker();

  // Wire status changes to SSE.
  status.onChange((s, file) => {
    sse.publish("agents", { event: "agent-changed", data: { file, status: s } });
  });

  const server = startServer(config, {
    status, audit, logs: logsStore, conv, disk, sse, dashAudit,
    cleanupScript: args.cleanupScript, version: VERSION,
  });

  const url = `http://${config.host}:${config.port}/#token=${token}`;
  console.log(`kapsis-dashboard ${VERSION} listening on http://${config.host}:${config.port}`);
  console.log(`  bearer token: ${token}`);
  console.log(`  read-only:    ${config.readOnly}`);
  console.log(`  kapsis-home:  ${config.kapsisHome}`);
  console.log(`  open in browser: ${url}`);

  if (config.open) await openBrowser(url);

  const shutdown = async () => {
    log.info("shutting down");
    sse.close();
    status.close();
    server.stop(true);
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

void main().catch((e) => {
  console.error("fatal:", e);
  process.exit(1);
});
