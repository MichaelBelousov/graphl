import { describe, expect, it, setDefaultTimeout } from "bun:test";
import { compileGraphltSourceAndInstantiateProgram } from "../index.mts";

setDefaultTimeout(1_000_000); // might need to compile zig code

describe("js sdk", () => {
  it("return i32", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) i32)
      (define (foo) (return 2))
    `);
    expect(program.functions.foo()).toEqual(2);
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
