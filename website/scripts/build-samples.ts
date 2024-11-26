#!/usr/bin/env bun

import { $ } from "bun";
import * as fs from "node:fs";
import * as path from "node:path";

// FIXME: in parallel
for (const sample of await fs.promises.readdir("./src/samples")) {
  if (!sample.endsWith(".scm"))
    continue;
  const samplePath = path.join("./src/samples", sample);
  const wat = path.join("./src/samples", sample + ".wat")
  const wasm = path.join("./src/samples", sample + ".wasm")
  await $`../lang-lib/zig-out/bin/text-to-wasm --env 'Confetti(i32)' ${samplePath} > ${wat}`;
  await $`wat2wasm ${wat} > ${wasm}`;
}
