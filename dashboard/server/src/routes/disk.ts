import { json, type Router } from "../http";
import type { DiskUsageStore } from "../store/disk";

export function registerDiskRoutes(r: Router, deps: { disk: DiskUsageStore }): void {
  r.get("/api/v1/disk/usage", async () => json({ entries: await deps.disk.snapshot() }));
}
