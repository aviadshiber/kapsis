import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const SERVER = "http://127.0.0.1:7777";

export default defineConfig(({ mode }) => ({
  plugins: [react()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    // Production builds skip sourcemaps because the resulting .js.map
    // files get embedded into the compiled kapsis-dashboard binary (via
    // generate-ui-bundle.ts) and bloat it by ~2-5x the minified JS size
    // with no runtime payoff — Bun's server-side error reporter can't
    // apply browser source maps. The server-side bundle still gets
    // source maps via `bun build --compile --sourcemap` in CI.
    sourcemap: mode !== "production",
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": { target: SERVER, changeOrigin: true },
      "/sse": { target: SERVER, changeOrigin: true, ws: false },
    },
  },
}));
