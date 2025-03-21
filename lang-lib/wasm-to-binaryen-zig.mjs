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
const instructions = targetFunc.slice(targetFuncInstStart);

const localsTypes = [];
for (const local of targetFunc.slice(0, instructions)) {
  localTypes.push();
}

console.log(instructions);

let index = 0;
const resultChunks = [];

const BYN = process.env.PREFIX ?? "byn.c"

const transform = {
  "local.get"() {
    const localId = instructions[index + 1];
    console.log(`${BYN}.BinaryenLocalGet()`);
  }
};

while (index < instructions.length) {
  transform[instructions]();
}



