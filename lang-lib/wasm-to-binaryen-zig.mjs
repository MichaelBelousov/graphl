import child_process from "node:child_process";
import assert from "node:assert";
import parseSexp from "s-expression";

const [_runtimePath, _scriptPath, wasmFile, targetFuncName] = process.argv;
assert(wasmFile !== undefined);
assert(targetFuncName !== undefined);

const wat = child_process.execFileSync("wasm-tools", ["print", wasmFile], { encoding: "utf8" });

const sexp = parseSexp(wat);

const targetFuncIndex = sexp.find(s => s[0] === "export" && s[1] == "factorial")[2][1];


const targetFuncId = `;${targetFuncIndex};`;

const targetFunc = sexp.find(s => s[0] === "func" && s[1][0] === targetFuncId);
const targetFuncInstStart = targetFunc.findIndex(s => s !== "func" && ![targetFuncId, "type", "param", "result"].includes(s[0]));
const targetFuncInstructions = targetFunc.slice(targetFuncInstStart);

console.log(targetFuncInstructions);

