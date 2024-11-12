import react from "@vitejs/plugin-react";
import rollupVisualizer from "rollup-plugin-visualizer";
import viteInspect from "vite-plugin-inspect";
import { defineConfig, loadEnv, PluginOption } from "vite";
import * as path from "node:path";
import * as fs from "node:fs";

const copyTypesPlugin = (): PluginOption => {
  return {
    name: 'copy-types',
    apply: 'build',
    closeBundle() {
      void fs.promises.copyFile(
        path.join(__dirname, "./WebBackend.d.ts"),
        path.join(__dirname, "./dist/grappl-ide-web.d.ts"),
      );
    }
  };
};

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
        // TODO: remove monaco support for other languages
    build: {
      lib: {
        entry: path.resolve(__dirname, "./entry.ts"),
        name: "GrapplIdeWeb",
        fileName: (format, _entryName) => {
          return `grappl-ide-web.${format}.js`
        },
      },
      minify: mode === "production" && "esbuild",
      sourcemap: mode === "development",
      rollupOptions: {
        // NOTE: rollup plugins are mostly treated as vite plugins that take place after normal vite-plugins
        // they may not be compatible at all, so be warned
        plugins: [
          copyTypesPlugin(),
          ...(mode === "development" ? [rollupVisualizer()] : [])
        ],
        // NOTE: shouldn't be used afaict?
        external: ["react"],
      },
    },
    envPrefix: "GRAPPL_",
  };
});
