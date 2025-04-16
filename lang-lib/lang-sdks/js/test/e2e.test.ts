import { describe, expect, it, setDefaultTimeout } from "bun:test";
import { compileGraphltSourceAndInstantiateProgram } from "../index.mts";

setDefaultTimeout(1_000_000); // might need to compile zig code

describe("js sdk", () => {
  it("syntax error extra paren", async () => {
    expect(compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) i32)
      (define (foo) (return 2)))
    `)).rejects.toThrow(Error("Unmatched closer"));
    // TODO: handle full diagnostic from native library
  });

  it("return i32", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) i32)
      (define (foo) (return (* (+ 3 4) 5)))
    `);
    expect(program.functions.foo()).toEqual(35);
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
    expect(program.functions.factorial(5)).toEqual(120);
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
    expect(program.functions.factorial(10n)).toEqual(3628800n);
  });

  it("return string", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) string)
      (define (foo) (return "simple"))
    `);
    expect(program.functions.foo()).toEqual("simple");
  });

  it("return (string, i32)", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) (i32 string))
      (define (foo) (return 5 "hello"))
    `);
    expect(program.functions.foo()).toEqual([5, "hello"]);
  });
});
