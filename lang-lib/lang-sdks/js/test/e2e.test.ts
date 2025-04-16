import { describe, expect, it, setDefaultTimeout } from "bun:test";
import { compileGraphltSourceAndInstantiateProgram } from "../index.mts";

setDefaultTimeout(1_000_000); // might need to compile zig code

describe("js sdk", () => {
  it("simple string", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) i32)
      (define (foo) (return 2))
    `);
    expect(program.functions.foo()).toEqual(2);
  });
});
