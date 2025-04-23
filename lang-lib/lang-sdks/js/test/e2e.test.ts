import assert from "node:assert";
import { compileGraphltSourceAndInstantiateProgram, GraphlTypes } from "../index.mts";
let describe: import("bun:test").Describe;
let it: import("bun:test").Test;

if (typeof Bun === "undefined") {
  ({ describe, it } = (await import("node:test")) as any);
} else {
  ({ describe, it } = require("bun:test"));
  const { setDefaultTimeout } = require("bun:test");
  setDefaultTimeout(1_000_000); // might need to compile zig code
}

describe("js sdk", () => {
  it("syntax error extra paren", async () => {
    let err: any;
    try {
      await compileGraphltSourceAndInstantiateProgram(`
        (typeof (foo) i32)
        (define (foo) (return 2)))
      `)
    } catch (_err) {
      err = _err;
    }
    assert.strictEqual(
      err.message,
      "Closing parenthesis with no opener:\n" +
      " at unknown:3:34\n" +
      "  |         (define (foo) (return 2)))\n" +
      "                                     ^"
    );
  });

  it("return i32", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) i32)
      (define (foo) (return (* (+ 3 4) 5)))
    `);
    assert.strictEqual(program.functions.foo(), 35);
  });

  it("factorial recursive", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (factorial i32) i32)
      (define (factorial n)
        (begin
          (if (<= n 1)
              (begin (return 1))
              (begin (return (* n (factorial (- n 1))))))))
    `);
    assert.strictEqual(program.functions.factorial(5), 120);
  });

  it("factorial iterative", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (meta version 1)
      (typeof (factorial i64) i64)
      (define (factorial n)
        (typeof acc i64)
        (define acc 1)
        <!if
        (if (<= n 1)
            (return acc)
            (begin
              (set! acc (* acc n))
              (set! n (- n 1))
              >!if)))
      
    `);
    assert.strictEqual(program.functions.factorial(10n), 3628800n);
  });

  it("return string", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) string)
      (define (foo) (return "simple"))
    `);
    assert.strictEqual(program.functions.foo(), "simple");
  });

  it("return (i32 i32)", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) (i32 i32))
      (define (foo) (return 5 10))
    `);
    assert.partialDeepStrictEqual(program.functions.foo(), { 0: 5, 1: 10 });
  });

  it("return (i32)", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) (i32))
      (define (foo) (return 5))
    `);
    assert.deepEqual(program.functions.foo(), 5);
  });

  it("no return", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) ())
      (define (foo) (+ 2 5))
    `);
    assert.deepEqual(program.functions.foo(), undefined);
  });

  it("return (string i32)", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) (i32 string))
      (define (foo) (return 5 "hello"))
    `);
    assert.partialDeepStrictEqual(program.functions.foo(), { 0: 5,  1: "hello" });
  });

  it("pass vec3", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (make) vec3)
      (define (make) (begin (return 1.2 3.4 5.6789)))
      (typeof (take vec3) f64)
      (define (take v) (return (.z v)))
    `);

    const makeResult = program.functions.make();
    const takeResult = program.functions.take(makeResult);
    assert.strictEqual(takeResult, 5.6789);
  });

  it("vec3 param", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (processInstance u64
                               vec3
                               vec3)
              string)
      (define (processInstance MeshId
                               Origin
                               Rotation)
              (begin (return "my_export")))
      (typeof (main)
              i32)
      (define (main)
              (begin (Confetti 100)
                     (return 0)))
    `, {
      Confetti: {
        name: "Confetti",
        inputs: [{ type: GraphlTypes.i32 }],
        outputs: [],
      },
    });

    assert.deepStrictEqual(program.functions.processInstance(
      0xffff_ffff_ffff_ffffn,
      { x: 1, y: 2, z: 3 },
      { x: 4.5, y: 6.7, z: 8.9 },
    ), "my_export");
  });

  it("call user func", async () => {
    let called = false;
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (main)
              i32)
      (define (main)
              (begin (Confetti 100)
                     (return 0)))
    `, {
      Confetti: {
        name: "Confetti",
        inputs: [{ type: GraphlTypes.i32 }],
        outputs: [],
        impl(param) {
          assert.strictEqual(param, 100);
          called = true;
        }
      },
    });

    assert.deepStrictEqual(program.functions.main(), 0);
    assert(called);
  });
});
