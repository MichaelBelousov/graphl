let describe: import("bun:test").Describe;
let it: import("bun:test").Test;
import assert from "node:assert";

// TODO: move these tests to a separate package to consume bundle directly
// local (native) backend
import { compileGraphltSourceAndInstantiateProgram, GraphlTypes } from "../index.mts";
// import { compileGraphltSourceAndInstantiateProgram, GraphlTypes } from "../dist/native-cjs/index.js";
// production wasm backend
//import { compileGraphltSourceAndInstantiateProgram, GraphlTypes } from "../dist/cjs/index.js";

if (typeof Bun === "undefined") {
  ({ describe, it } = (await import("node:test")) as any);
} else {
  ({ describe, it } = require("bun:test"));
  const { setDefaultTimeout } = require("bun:test");
  setDefaultTimeout(1_000_000); // might need to compile zig code
}

describe("compiler types", () => {
  it.only("return i32", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (meta version 1)

      (struct foobar
        (foo i32 0) ;; NOTE: defaults not implemented yet
        (bar string "default"))

      ;; would be interesting to have a symmetric named field initializer syntax:
      ;; (foobar (.bar "hello"))

      (typeof (main foobar) foobar)
      (define (main arg)
        ;; TODO: allow returning structs directly...
        (foobar (+ (.foo arg) 1)
                "hello")
        (return (+ (.foo arg) 1)
                "hello"))
    `);
    assert.strictEqual(program.functions.main({ foo: 1, bar: "world" }), { foo: 2, bar: "hello" });
  });
});
