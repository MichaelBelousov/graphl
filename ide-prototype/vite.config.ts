import react from "@vitejs/plugin-react";
import rollupVisualizer from "rollup-plugin-visualizer";
import viteInspect from "vite-plugin-inspect";
import { defineConfig, loadEnv } from "vite";
import * as path from "node:path";

export default defineConfig(async ({ mode }) => {
  Object.assign(process.env, loadEnv(mode, process.cwd(), ""));

  return {
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
    build: {
      lib: {
        entry: path.resolve(__dirname, "./entry.ts"),
        name: "GrapplIdeWeb",
        fileName: "grappl-ide-web",
      },
      minify: mode === "production" && "esbuild",
      sourcemap: mode === "development",
      rollupOptions: {
        // NOTE: rollup plugins are mostly treated as vite plugins that take place after normal vite-plugins
        // they may not be compatible at all, so be warned
        plugins: [...(mode === "development" ? [rollupVisualizer()] : [])],
        // NOTE: shouldn't be used afaict?
        external: ["react"],
      },
    },
    envPrefix: "GRAPPL_",
  };
});
