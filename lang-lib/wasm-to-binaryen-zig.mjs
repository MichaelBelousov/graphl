import child_process from "node:child_process";
import assert from "node:assert";
import parseSexp from "s-expression";

const [_runtimePath, _scriptPath, wasmFile] = process.argv;
assert(wasmFile !== undefined);

const wat = child_process.execFileSync("wasm-tools", ["print", wasmFile], { encoding: "utf8" });

console.log(wat);

const sexp = parseSexp(wat);

console.log(sexp);

