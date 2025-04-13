#!/usr/bin/env bun

import fs from "node:fs";

// TODO: use the JS SDK to orchestrate calls like this
const wasm = await WebAssembly.instantiate(fs.readFileSync("/tmp/compiler-test.wasm"), {
    env: {
        callUserFunc_R_vec3(ptr: number) {
          const vec3_view = new DataView(wasm.instance.exports.memory.buffer, ptr, 24);
          vec3_view.setFloat64(0, 1.23);
          vec3_view.setFloat64(8, 4.56);
          vec3_view.setFloat64(16, 7.89);
        }
    }
});

const str = wasm.instance.exports.simple();
console.log("str", str)
const written = wasm.instance.exports.__graphl_host_copy(str, 1);
console.log("written", written)

const view = new DataView(wasm.instance.exports.memory.buffer, 1024, written);
const td = new TextDecoder();
console.log(td.decode(view));
console.log(new Array(written).fill().map((_, i) => view.getUint8(i)));
