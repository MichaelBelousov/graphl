#!/usr/bin/env node

import esbuild from "esbuild";
import * as fs from "node:fs";
import * as path from "node:path";

const distFolder = "dist";

await esbuild.build({
  entryPoints: ["./entry.ts"],
  entryNames: "[dir]/graphl-ide-web.es",
  format: "esm",
  bundle: true,
  external: ["react"],
  loader: {
    //".wasm": "file",
    ".wasm": "copy",
  },
  outdir:distFolder,
}),

await Promise.all([
  fs.promises.copyFile(path.join(import.meta.dirname, "./WebBackend.d.ts"), `./${distFolder}/graphl-ide-web.d.ts`),
]);
