import { useEffect, useState } from "react";
import { api, ApiError, hasToken } from "./api/client";
import { AgentList } from "./views/AgentList";
import { AgentDetail } from "./views/AgentDetail";
import { DiskUsage } from "./views/DiskUsage";
import { Maintenance } from "./views/Maintenance";

type Tab = "agents" | "disk" | "maintenance";

interface Route {
  tab: Tab;
  agentId: string | null;
}

function parseRoute(): Route {
  const m = window.location.hash.match(/^#\/agent\/([^/]+)/);
  if (m) return { tab: "agents", agentId: decodeURIComponent(m[1]!) };
  if (window.location.hash.startsWith("#/disk")) return { tab: "disk", agentId: null };
  if (window.location.hash.startsWith("#/maintenance")) return { tab: "maintenance", agentId: null };
  return { tab: "agents", agentId: null };
}

const TOKEN_HINT = "Bearer token missing or invalid. Append #token=… to the URL (from the server stdout).";

export function App() {
  const [route, setRoute] = useState<Route>(parseRoute);
  const [version, setVersion] = useState<{ version: string; readOnly: boolean } | null>(null);
  const [authError, setAuthError] = useState<string | null>(hasToken() ? null : TOKEN_HINT);

  useEffect(() => {
    api.version().then(setVersion).catch(() => { /* version is public; ignore */ });
    if (hasToken()) {
      api.agents().catch((e: unknown) => {
        if (e instanceof ApiError && e.status === 401) {
          setAuthError(TOKEN_HINT);
        }
      });
    }
    const onHash = () => setRoute(parseRoute());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  if (authError) {
    return (
      <div style={{ padding: 40 }}>
        <h1>kapsis-dashboard</h1>
        <div className="banner">{authError}</div>
      </div>
    );
  }

  return (
    <div className="app">
      <aside className="sidebar">
        <h1>Kapsis</h1>
        <a className={`nav-item ${route.tab === "agents" ? "active" : ""}`} href="#/">Agents</a>
        <a className={`nav-item ${route.tab === "disk" ? "active" : ""}`} href="#/disk">Disk usage</a>
        <a className={`nav-item ${route.tab === "maintenance" ? "active" : ""}`} href="#/maintenance">Maintenance</a>
        <div style={{ flex: 1 }} />
        {version && (
          <div style={{ fontSize: 11, color: "var(--fg-muted)" }}>
            v{version.version}{version.readOnly ? " · read-only" : ""}
          </div>
        )}
      </aside>
      <main className="main">
        {route.tab === "agents" && route.agentId === null && (
          <AgentList onSelect={(id) => { window.location.hash = `#/agent/${encodeURIComponent(id)}`; }} />
        )}
        {route.tab === "agents" && route.agentId !== null && (
          <AgentDetail agentId={route.agentId} readOnly={version?.readOnly ?? true} onBack={() => { window.location.hash = "#/"; }} />
        )}
        {route.tab === "disk" && <DiskUsage />}
        {route.tab === "maintenance" && <Maintenance readOnly={version?.readOnly ?? true} />}
      </main>
    </div>
  );
}
