#!/usr/bin/env bun

import fs from "node:fs";
import assert from "node:assert";
import { instantiateProgramFromWasmBuffer } from "../js-sdk.mts";

const program = await instantiateProgramFromWasmBuffer(fs.readFileSync("/tmp/compiler-test.wasm"));

const functionToCall = process.env.FUNC_NAME;
assert(functionToCall !== undefined);

let args = [];
if (process.env.ARGS) {
    args = eval('[' + process.env.ARGS + ']');
}

const result = program.functions[functionToCall](...args);
console.log(result);
