import * as esbuild from "esbuild";
import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import child_process from "node:child_process";

const dirname = path.dirname(url.fileURLToPath(import.meta.url));

async function main() {
  if (!process.env.SKIP_BUNDLE) {
    console.log("esbuild...");
    await esbuild.build({
      bundle: true,
      platform: "node",
      outdir: path.join(dirname, "./dist/native-cjs"),
      target: "node20",
      external: [
        "*.zig", // for dev builds
        "*.zigar",
        "node-zigar", // uses a worker script so can't be bundled
      ],
      entryPoints: [
        path.join(dirname, "./index.mts"),
      ],
      define: {
        "globalThis._GRAPHL_JS_NATIVE": JSON.stringify(true),
      },
    });
    console.log("done!");
  }

  console.log("copying files and building zigar bundle in parallel...");
  if (!process.env.SKIP_ZIGAR_BUILD) {
    try {
      await fs.promises.rename("./node-zigar.config.template.json", "./node-zigar.config.json");
    } catch {}

    try {
      await Promise.all([
        new Promise((resolve, reject) => {
          const proc = child_process.spawn(
            path.join(dirname, "../../../node_modules/.bin/node-zigar"),
            ["build"],
            {
              shell: true,
              cwd: path.join(dirname, "zig"),
              stdio: ["inherit", "inherit", "inherit"],
            },
          );
          proc.on("error", reject);
          proc.on("exit", (code, signal) => {
            if (code !== 0) reject(Error(`Nonzero code (${code})`));
            if (signal) reject(Error(`Signal (${signal})`));
            else resolve();
          });
        }),
      ]);
    } finally {
      try {
        await fs.promises.rename("./node-zigar.config.json", "./node-zigar.config.template.json");
      } catch {}
    }
  }

  // await fs.promises.cp(
  //   "../../../node_modules/node-zigar-addon/.zig-cache/",
  // );
}

void main();
