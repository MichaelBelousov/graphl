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
  external: [
    "react", // FIXME: do I even use this?
    "node-zigar", // FIXME try to remove this
    // zigar `nodeCompat: true` uses these node packages as externals
    "fs/promises",
    "url",
    // we optionally use wasi in the js-sdk
    "node:wasi",
  ],
  loader: {
    ".wasm": "copy",
  },
  outdir:distFolder,
}),

await Promise.all([
  fs.promises.copyFile(path.join(import.meta.dirname, "./WebBackend.d.ts"), `./${distFolder}/graphl-ide-web.d.ts`),
]);
