import { describe, expect, it } from "bun:test";
import { compileGraphltSourceAndInstantiateProgram } from "../index.mts";

describe("e2e", () => {
  it("simple string", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) i32)
      (define (foo) (return 2))
    `)
    expect(program.functions.foo()).toEqual(2);
  });
});
