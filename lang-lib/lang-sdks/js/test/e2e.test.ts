import { describe, expect, it } from "bun:test";
import { compileGraphltSourceAndInstantiateProgram } from "../index.mts";

// NOTE: preloads don't seem to work in bun test, need to figure out path around that
// describe("e2e", () => {
//   it("simple string", async () => {
//     const program = await compileGraphltSourceAndInstantiateProgram(`
//       (typeof (foo) i32)
//       (define (foo) (return 2))
//     `)
//     expect(program.functions.foo()).toEqual(2);
//   });
// });

async function test() {
  const program = await compileGraphltSourceAndInstantiateProgram(`
    (typeof (foo) i32)
    (define (foo) (return 2))
  `)
  expect(program.functions.foo()).toEqual(2);
}

test();
