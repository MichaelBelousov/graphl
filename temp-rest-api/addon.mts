import assert from "node:assert"
import { createRequire } from "node:module"
import path from "node:path"

// TODO: import.meta.resolve()
// @ts-ignore
const modulesPath = path.dirname(new URL(import.meta.url).pathname)
const require = createRequire(modulesPath);

let nativeBindings;
try {
  nativeBindings = require("./build/Debug/addon.node");
} catch {
  nativeBindings = require("./build/Release/addon");
}

assert(nativeBindings);

export const graph_to_source: (json: string) => string = nativeBindings.graph_to_source;
export const source_to_graph: (json: string) => string = nativeBindings.source_to_graph;
