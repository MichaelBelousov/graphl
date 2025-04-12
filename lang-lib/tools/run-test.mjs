#!/usr/bin/env node
// TODO: see if bun works

import fs from "node:fs";

const wasm = await WebAssembly.instantiate(fs.readFileSync("/tmp/compiler-test.wasm"));

const str = wasm.instance.exports.simple();
console.log("str", str)
const written = wasm.instance.exports.__graphl_host_copy(str, 1);
console.log("written", written)

const view = new DataView(wasm.instance.exports.memory.buffer, 1024, written);
const td = new TextDecoder();
console.log(td.decode(view));
console.log(new Array(written).fill().map((_, i) => view.getUint8(i)));
