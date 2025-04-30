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
  await fs.promises.mkdir(
    path.join(dirname, "../../lib/node_modules/@bentley"),
    { recursive: true }
  );

  await fs.promises.rename("./node-zigar.config.template.json", "./node-zigar.config.json");
  try {
    await Promise.all([
      new Promise((resolve, reject) => {
        child_process.spawn(
          path.join(dirname, "../../node_modules/.bin/node-zigar"),
          ["build"],
          {
            shell: true,
            cwd: path.join(dirname, "zig"),
            stdio: ["inherit", "inherit", "inherit"],
          },
          (err) => {
            if (err) reject(err);
            else resolve();
          }
        );
      }),
    ]);
  } finally {
    try {
      await fs.promises.rename("./node-zigar.config.json", "./node-zigar.config.template.json");
    } catch {}
  }
}

void main();
