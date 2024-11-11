import react from "@vitejs/plugin-react";
import rollupVisualizer from "rollup-plugin-visualizer";
import viteInspect from "vite-plugin-inspect";
import { defineConfig, loadEnv } from "vite";
import * as path from "node:path";
import * as fs from "node:fs";

// TODO: use vite approved way to ship library types
fs.copyFileSync(
  path.join(__dirname, "./WebBackend.d.ts"),
  path.join(__dirname, "./dist/WebBackend.d.ts"),
);

export default defineConfig(async ({ mode }) => {
  Object.assign(process.env, loadEnv(mode, process.cwd(), ""));

  return {
    base: "grappl-demo",
    server: {
      port: 3000,
      strictPort: true,
    },
    plugins: [
      react(),
      ...(mode === "development" ? [viteInspect({ build: true })] : []),
    ],
    css: {
      preprocessorOptions: {
        includePaths: ["node_modules"],
      },
    },
    optimizeDeps: {
      extensions: [".scss"],
      esbuildOptions: {
        loader: {
          ".svg": "dataurl",
          ".woff": "dataurl",
          ".eot": "dataurl",
          ".ttf": "dataurl",
          ".woff2": "dataurl",
          ".cur": "dataurl",
        },
      },
    },
        // TODO: remove monaco support for other languages
    build: {
      minify: mode === "production" && "esbuild",
      sourcemap: mode === "development",
      rollupOptions: {
        // NOTE: rollup plugins are mostly treated as vite plugins that take place after normal vite-plugins
        // they may not be compatible at all, so be warned
        plugins: [...(mode === "development" ? [rollupVisualizer()] : [])],
        // NOTE: shouldn't be used afaict?
      },
    },
    envPrefix: "GRAPPL_",
  };
});
