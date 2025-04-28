#!/usr/bin/env bun

import fs from "node:fs";
import assert from "node:assert";
import { instantiateProgramFromWasmBuffer, GraphlTypes } from "../lang-sdks/js/index.mts";

const program = await instantiateProgramFromWasmBuffer(fs.readFileSync("/tmp/compiler-test.wasm"), {
    ModelCenter: {
        name: "ModelCenter",
        inputs: [],
        outputs: [{ type: GraphlTypes.string }],
        impl: () => {
            return { x: 1.23, y: 4.56, z: 7.89 };
        },
    },
});

const functionToCall = process.env.CALL_FUNC;
assert(functionToCall !== undefined);

let args = [];
if (process.env.ARGS) {
    args = eval('[' + process.env.ARGS + ']');
}

const result = program.functions[functionToCall](...args);
console.log(result);
