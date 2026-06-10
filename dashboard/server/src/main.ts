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
import { SpecStore, loadProgressInstructions } from "./store/spec";
import { GistHistoryStore } from "./store/gist-history";
import { DashboardAuditWriter } from "./control/audit-writer";
import { CleanupRunner } from "./control/cleanup";
import { SseBroker } from "./sse";
import { EphemeralTokenStore } from "./sse-tokens";
import { log } from "./logger";

const VERSION = "0.1.0";

interface Args {
  port: number;
  host: string;
  kapsisHome: string;
  readOnly: boolean;
  open: boolean;
  token: string | null;
  showToken: boolean;
  allowNonLocalhost: boolean;
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
      "show-token": { type: "boolean", default: false },
      "allow-non-localhost": { type: "boolean", default: false },
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
    showToken: Boolean(values["show-token"]) || process.env.KAPSIS_DASHBOARD_SHOW_TOKEN === "true",
    allowNonLocalhost: Boolean(values["allow-non-localhost"]),
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
  --port <n>              HTTP port (default ${DEFAULT_PORT})
  --host <addr>           Bind address (default ${DEFAULT_HOST}); see --allow-non-localhost
  --kapsis-home <path>    Root of ~/.kapsis (default $KAPSIS_HOME or ~/.kapsis)
  --read-only             Disable destructive endpoints
  --open                  Open the dashboard URL in a browser at startup
  --token <s>             Use a fixed bearer token instead of a random one
  --show-token            Print the bearer token to stdout (default: hidden;
                          the URL with #token= fragment is always printed)
  --allow-non-localhost   Required when --host is not 127.0.0.1 / localhost / ::1.
                          Exposes destructive endpoints to the network; only the
                          bearer token gates access. Strongly discouraged.
  --ui-dist <path>        Serve a Vite-built UI bundle from this dir (dev override)
  --cleanup-script <p>    Path to scripts/kapsis-cleanup.sh
  -v, --version           Print version and exit
  -h, --help              Show this help

ENVIRONMENT
  KAPSIS_DASHBOARD_SHOW_TOKEN=true   Equivalent to --show-token
`);
}

const LOCALHOST_HOSTS = new Set(["127.0.0.1", "localhost", "::1", "0:0:0:0:0:0:0:1"]);

function isLocalhost(host: string): boolean {
  return LOCALHOST_HOSTS.has(host.toLowerCase());
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

  if (!isLocalhost(args.host) && !args.allowNonLocalhost) {
    console.error(
      `kapsis-dashboard: --host '${args.host}' is not a loopback address. ` +
      `This would expose destructive endpoints (kill / cleanup) to the network ` +
      `behind only a bearer token. Re-run with --allow-non-localhost if that is ` +
      `truly intended; prefer SSH port-forwarding instead.`,
    );
    process.exit(2);
  }
  if (!isLocalhost(args.host) && args.allowNonLocalhost) {
    console.error(
      `WARNING: binding to non-loopback ${args.host} — destructive endpoints ` +
      `are now reachable over the network. Anyone who can read your bearer ` +
      `token from stdout/shell-history/process-args can kill your agents.`,
    );
  }

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
  // Loaded once at startup. When null (Kapsis install missing), the splitter
  // no-ops and the UI shows the full file content. Better degrade than break.
  const injectedSuffix = await loadProgressInstructions();
  const spec = new SpecStore(status, p.specs, p.worktrees, { injectedSuffix });
  const dashAudit = new DashboardAuditWriter(p.dashboardAudit);
  await dashAudit.init();
  const sse = new SseBroker();
  const sseTokens = new EphemeralTokenStore();
  const cleanupRunner = new CleanupRunner();
  const gistHistory = new GistHistoryStore(status, sse);
  gistHistory.init();

  // Wire status changes to SSE.
  status.onChange((s, file) => {
    sse.publish("agents", { event: "agent-changed", data: { file, status: s } });
  });

  const server = startServer(config, {
    status, audit, logs: logsStore, conv, disk, spec, gistHistory,
    sse, dashAudit, sseTokens, cleanupRunner,
    cleanupScript: args.cleanupScript, version: VERSION,
  });

  const url = `http://${config.host}:${config.port}/#token=${token}`;
  console.log(`kapsis-dashboard ${VERSION} listening on http://${config.host}:${config.port}`);
  // The token is intentionally not printed by default — copy it from the URL
  // fragment below, which the browser never sends in network requests.
  if (args.showToken) {
    console.log(`  bearer token:  ${token}`);
  } else {
    const masked = token.slice(0, 6) + "…" + token.slice(-4);
    console.log(`  bearer token:  ${masked}  (--show-token to reveal)`);
  }
  console.log(`  read-only:     ${config.readOnly}`);
  console.log(`  kapsis-home:   ${config.kapsisHome}`);
  console.log(`  open browser:  ${url}`);

  if (config.open) await openBrowser(url);

  const shutdown = async () => {
    log.info("shutting down");
    // Best-effort close of every resource. If one throws (e.g. a watcher
    // already in teardown), we still want the remaining resources released
    // before the process exits — try-with-resources style. Errors are
    // logged at debug so a "noisy shutdown on SIGTERM" stays out of normal
    // operator output.
    const tryClose = (name: string, fn: () => void): void => {
      try { fn(); } catch (e) { log.debug(`shutdown: ${name}.close() threw`, { err: String(e) }); }
    };
    tryClose("gistHistory", () => gistHistory.close());
    tryClose("sse", () => sse.close());
    tryClose("sseTokens", () => sseTokens.close());
    tryClose("status", () => status.close());
    tryClose("server", () => server.stop(true));
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

void main().catch((e) => {
  console.error("fatal:", e);
  process.exit(1);
});
