import react from "@vitejs/plugin-react";
import rollupVisualizer from "rollup-plugin-visualizer";
import viteInspect from "vite-plugin-inspect";
import { defineConfig, loadEnv } from "vite";

export default defineConfig(async ({ mode }) => {
  Object.assign(process.env, loadEnv(mode, process.cwd(), ""));

  // TODO: use node version that supports require?
  const zigar = (await import("rollup-plugin-zigar")).default;

  return {
    server: {
      port: 3000,
      strictPort: true,
    },
    plugins: [
      react(),
      zigar({
        topLevelAwait: false,
        optimize: mode === 'production' ? 'ReleaseSmall' : 'Debug',
      }),
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
    define: {
      "process.env": process.env,
    },
    build: {
      minify: mode === "production" && "esbuild",
      sourcemap: mode === "development",
      rollupOptions: {
        // NOTE: rollup plugins are mostly treated as vite plugins that take place after normal vite-plugins
        // they may not be compatible at all, so be warned
        plugins: [...(mode === "development" ? [rollupVisualizer()] : [])],
      },
    },
    envPrefix: "MDXEDIT_",
  };
});
