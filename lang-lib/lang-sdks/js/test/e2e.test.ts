let describe: import("bun:test").Describe;
let it: import("bun:test").Test;
import assert from "node:assert";

// TODO: move these tests to a separate package to consume bundle directly
// local (native) backend
import { compileGraphltSourceAndInstantiateProgram, GraphlTypes } from "../index.mts";
// production wasm backend
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

  it("take return bool", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo bool) bool)
      ;; FIXME: I hate this syntax, parse the symbol "true" instead
      (define (foo c) (return (or c #t)))
    `);
    assert.partialDeepStrictEqual(program.functions.foo(false), true);
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

  // FIXME: there's a bug when this is run after other code that probably generates and
  // saves a "foo" type in global state (BinaryenHelper?) somewhere that must be ignored
  it("return (string i32)", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) (i32 string))
      (define (foo) (return 5 "hello"))
    `);
    assert.partialDeepStrictEqual(program.functions.foo(), { 0: 5,  1: "hello" });
  });

  it("return (string i32 bool)", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) (i32 string bool))
      (define (foo) (return 5 "hello" #t))
    `);
    assert.partialDeepStrictEqual(program.functions.foo(), { 0: 5,  1: "hello", 2: true });
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

  it("pass string", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (first string) string)
      (define (first s) (return s))
      (typeof (second string) string)
      (define (second s) (return s))
    `);

    const param = "test-me";
    const firstResult = program.functions.first(param);
    assert.strictEqual(firstResult, param);
    const secondResult = program.functions.second(firstResult);
    assert.strictEqual(secondResult, param);
  });

  it("vec3 param", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (import Confetti "host/Confetti")
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
      (import Confetti "host/Confetti")
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
        impl(param: number) {
          assert.strictEqual(param, 100);
          called = true;
        }
      },
    });

    assert.strictEqual(program.functions.main(), 0);
    assert(called);
  });

  it("imports", async () => {
    let called = false;
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (import JavaScript-Eval "host/JavaScript-Eval")
      (import Confetti "host/Confetti")

      (typeof (processInstance u64 vec3 vec3)
              string)
      (define (processInstance MeshId Origin Rotation)
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
        impl(param: number) {
          console.log(param);
          called = true;
        }
      },
      "JavaScript-Eval": {
        inputs: [
          { name: "elementId", type: GraphlTypes.u64 },
          { name: "code", type: GraphlTypes.string },
        ],
        outputs: [{ name: "JSON result", type: GraphlTypes.string }],
        tags: ["text"],
        /**
         * @param {bigint} elemId
         * @param {string} code
         * @returns {string}
         */
        impl(elemId, code) {
          //return JSON.stringify(eval(code) ?? null);
        }
      },
    });

    assert.strictEqual(program.functions.main(), 0);
    assert.strictEqual(program.functions.processInstance(0n, {x: 0, y: 0, z: 0}, {x: 1, y: 1, z: 1}), "my_export");
    assert(called);
  });

  it.skip("imports 2", async () => {
    let called = false;
    const program = await compileGraphltSourceAndInstantiateProgram(`
        (import JavaScript-Eval "host/JavaScript-Eval")
        (import ModelCenter "host/ModelCenter")
        (import FROM "host/FROM")
        (import WHERE "host/WHERE")
        (import SELECT "host/SELECT")
        (import Confetti "host/Confetti")
        (typeof (main)
                i32)
        (define (main)
                (begin (ModelCenter)
                       (Confetti 100)
                       (return 0)))
    `, {
      Confetti: {
        name: "Confetti",
        inputs: [{ type: GraphlTypes.i32 }],
        outputs: [],
        impl(param: number) {
          console.log(param);
          called = true;
        }
      },
      "JavaScript-Eval": {
        inputs: [
          { name: "elementId", type: GraphlTypes.u64 },
          { name: "code", type: GraphlTypes.string },
        ],
        outputs: [{ name: "JSON result", type: GraphlTypes.string }],
        tags: ["text"],
        /**
         * @param {bigint} elemId
         * @param {string} code
         * @returns {string}
         */
        impl(elemId, code) {}
      },
      "ModelCenter": {
        inputs: [],
        outputs: [{ name: "", type: GraphlTypes.vec3 }],
        impl() { return { x: 1, y: 2, z: 3 }; },
      },
      "FROM": {
        inputs: [],
        outputs: [],
        impl() {},
      },
      "WHERE": {
        inputs: [],
        outputs: [],
        impl() {},
      },
      "SELECT": {
        inputs: [],
        outputs: [],
        impl() {},
      },
      // (import testme "host/testme")
      // (import ECSQL-exec "host/ECSQL-exec")
    });

    assert.strictEqual(program.functions.main(), 0);
    assert(called);
  });

  it("complicated return and label", async () => {
    let called = false;
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (import NoClusterId "host/NoClusterId")
      (typeof (processInstance u64 u64 vec3 vec3)
              (string u64 string))
      (define (processInstance ElementId GeometrySourceId Origin Rotation)
              (begin 
                     <!__label1
                     (NoClusterId)
                     (return "imodel"
                            #!__label1
                             "/ITwinUnrealWorkshop/M_combinedMesh.M_combinedMesh")))
    `, {
      NoClusterId: {
        outputs: [{ type: GraphlTypes.u64 }],
        impl() {
          called = true;
          return 2n;
        }
      },
    });
    assert.partialDeepStrictEqual(
        program.functions.processInstance(10n, 10n, {x: 0, y: 0, z: 0}, {x: 1, y: 1, z: 1}),
        { 0: "imodel", 1: 2n, 2: "/ITwinUnrealWorkshop/M_combinedMesh.M_combinedMesh" },
    );
    assert(called);
  });

  it("graph label before", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (import NoClusterId "host/NoClusterId")
      (typeof (processInstance u64 u64 vec3 vec3)
              (string u64 string))
      (define (processInstance ElementId GeometrySourceId Origin Rotation)
              (begin 
                     <!__label1
                     (NoClusterId)
                     (return "imodel" #!__label1 "/ITwinUnrealWorkshop/M_combinedMesh.M_combinedMesh")))
    `, {
      NoClusterId: {
        outputs: [{ type: GraphlTypes.u64 }],
        impl() {
          return 3n;
        }
      },
    });
    assert.partialDeepStrictEqual(
        program.functions.processInstance(10n, 10n, {x: 0, y: 0, z: 0}, {x: 1, y: 1, z: 1}),
        { 0: "imodel", 1: 3n, 2: "/ITwinUnrealWorkshop/M_combinedMesh.M_combinedMesh" },
    );
  });

  it("graph label after", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (import NoClusterId "host/NoClusterId")
      (typeof (processInstance u64 u64 vec3 vec3)
              (string u64 string))
      (define (processInstance ElementId GeometrySourceId Origin Rotation)
              (begin 
                     (NoClusterId) <!__label1
                     (return "imodel" #!__label1 "/ITwinUnrealWorkshop/M_combinedMesh.M_combinedMesh")))
    `, {
      NoClusterId: {
        outputs: [{ type: GraphlTypes.u64 }],
        impl() {
          return 3n;
        }
      },
    });
    assert.partialDeepStrictEqual(
        program.functions.processInstance(10n, 10n, {x: 0, y: 0, z: 0}, {x: 1, y: 1, z: 1}),
        { 0: "imodel", 1: 3n, 2: "/ITwinUnrealWorkshop/M_combinedMesh.M_combinedMesh" },
    );
  });

  it("pure userfunc", async () => {
    let called = false;
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (import NoClusterId "host/NoClusterId")
      (typeof (processInstance u64 u64 vec3 vec3)
              (string u64 string))
      (define (processInstance ElementId GeometrySourceId Origin Rotation)
              (begin 
                     (return "imodel"
                             (NoClusterId)
                             "/ITwinUnrealWorkshop/M_combinedMesh.M_combinedMesh")))
    `, {
      NoClusterId: {
        outputs: [{ type: GraphlTypes.u64 }],
        kind: "pure",
        impl() {
          called = true;
          return 2n;
        }
      },
    });
    assert.partialDeepStrictEqual(
        program.functions.processInstance(10n, 10n, {x: 0, y: 0, z: 0}, {x: 1, y: 1, z: 1}),
        { 0: "imodel", 1: 2n, 2: "/ITwinUnrealWorkshop/M_combinedMesh.M_combinedMesh" },
    );
    assert(called);
  });

  it("u64 to f64 implicit", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (make_u64) u64)
      (define (make_u64) (return 1))
      (typeof (to_f64) f64)
      (define (to_f64) (return (make_u64)))
    `);
    assert.strictEqual(program.functions.to_f64(), 1.0);
  });

  it("select u64", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (foo) u64)
      (define (foo) (return (select 3 5 #f)))
    `);
    assert.strictEqual(program.functions.foo(), 5n);
  });
});
