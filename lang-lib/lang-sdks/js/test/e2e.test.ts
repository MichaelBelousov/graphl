// TODO: make it possible to detect bun vs node
import { describe, expect, it, setDefaultTimeout } from "bun:test";
// import { describe, it } from "node:test";
import assert from "node:assert";
import { compileGraphltSourceAndInstantiateProgram } from "../index.mts";

setDefaultTimeout(1_000_000); // might need to compile zig code

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
    assert.deepStrictEqual(err, Error("Unmatched closer"));
    // TODO: handle full diagnostic from native library
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
    assert.deepStrictEqual(program.functions.foo(), [5, 10]);
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

  it("return (string, i32)", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) (i32 string))
      (define (foo) (return 5 "hello"))
    `);
    assert.deepStrictEqual(program.functions.foo(), [5, "hello"]);
  });
});
