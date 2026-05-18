import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const SERVER = "http://127.0.0.1:7777";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: true,
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": { target: SERVER, changeOrigin: true },
      "/sse": { target: SERVER, changeOrigin: true, ws: false },
    },
  },
});
