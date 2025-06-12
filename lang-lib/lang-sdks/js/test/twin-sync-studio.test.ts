let describe: import("bun:test").Describe;
let it: import("bun:test").Test;
import assert from "node:assert";

// TODO: move these tests to a separate package to consume bundle directly
// local (native) backend
import { compileGraphltSourceAndInstantiateProgram, GraphlTypes, type GraphlHostEnv } from "../index.mts";
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
  it("full twin sync studio", async () => {
    /** @type {Record<string, import("@graphl/compiler-js").UserFuncDesc<any>>} */
    const graphlHostEnv = {
        VisibleInViewport: {
            inputs: [{ name: "ElementId", type: "u64" }],
            outputs: [{ name: "", type: "bool" }],
            kind: "pure",
            /**
             * @param {bigint} elemIdInt
             * @returns {boolean}
             */
            impl(elemIdInt) {
                // FIXME: technically it is a bug if this is undefined and this node is called...
                if (visibilitySet === undefined) return true;
                const elemId64 = elemIdInt === 0n ? "0" : `0x${elemIdInt.toString(16)}`;
                const result = visibilitySet.has(elemId64.toString())
                return result;
            }
        },
        ProjectCenter: {
            outputs: [{ name: "", type: "vec3" }],
            kind: "pure",
            impl() {
                return {
                    x: db.projectExtents.center.x,
                    y: db.projectExtents.center.y,
                    z: db.projectExtents.center.z,
                };
            },
        },

        Category: {
            inputs: [{ name: "Element", type: "u64" }],
            outputs: [{ name: "", type: "u64" }],
            kind: "pure",
            /**
             * @param {bigint} elemIdInt
             * @returns {bigint}
             */
            impl(elemIdInt) {
                const elemId64 = elemIdInt === 0n ? "0" : `0x${elemIdInt.toString(16)}`;
                // FIXME: preload a map of these if it is in the script...
                // loading is very slow
                /** @type {coreBackend.GeometricElement3d | undefined} */
                const elem = db.elements.tryGetElement(elemId64, coreBackend.GeometricElement3d);
                if (elem === undefined) return 0n;
                return BigInt(elem.category);
            }
        },

        Parent: {
            inputs: [{ name: "Element", type: "u64" }],
            outputs: [{ name: "", type: "u64" }],
            kind: "pure",
            /**
             * @param {bigint} elemIdInt
             * @returns {bigint}
             */
            impl(elemIdInt) {
                const elemId64 = elemIdInt === 0n ? "0" : `0x${elemIdInt.toString(16)}`;
                // FIXME: not performant
                const elem = db.elements.tryGetElement(elemId64);
                if (elem === undefined) return 0n;
                return BigInt(elem.parent?.id ?? 0);
            }
        },

        UserLabel: {
            inputs: [{ name: "Element", type: "u64" }],
            outputs: [{ name: "", type: "string" }],
            kind: "pure",
            /**
             * @param {bigint} elemIdInt
             * @returns {string}
             */
            impl(elemIdInt) {
                const elemId64 = elemIdInt === 0n ? "0" : `0x${elemIdInt.toString(16)}`;
                // FIXME: not performant
                const elem = db.elements.tryGetElement(elemId64);
                if (elem === undefined) return "";
                return elem.userLabel ?? "";
            }
        },

        // FIXME: remove
        // FIXME: replace with graphl native code which will be way faster cuz this copies everything in and out
        "CaselessMatch": {
            inputs: [
                { name: "Haystack", type: "string" },
                { name: "Needle", type: "string" },
            ],
            outputs: [{ name: "found", type: "bool" }],
            kind: "pure",
            /**
             * @param {string} haystack
             * @param {string} needle
             * @returns {boolean}
             */
            impl(haystack, needle) {
                return haystack.toLowerCase().includes(needle.toLowerCase());
            },
        },

        MeshVertexCount: {
            inputs: [{ name: "mesh id", type: "u64" }],
            outputs: [{ name: "", type: "i32" }],
            kind: "pure",
            /**
             * @param {bigint} meshId
             * @returns {number}
             */
            impl(meshId) {
                return meshIdToVertexCount.get(meshId) ?? 0;
            },
        },

        MetaClusterId: {
            outputs: [{ name: "id", type: "u64" }],
            impl: () => 0xffff_ffff_ffff_ffffn,
            kind: "pure",
        },

        NoClusterId: {
            outputs: [{ name: "id", type: "u64" }],
            impl: () => 0n,
            kind: "pure",
        },

        StringToU64: {
            inputs: [{ name: "", type: "string" }],
            outputs: [{ name: "", type: "u64" }],
            kind: "pure",
            /**
             * @param {string} str
             * @returns {bigint}
             */
            impl: (str) => BigInt(str),
        },

        MapByTable: {
            inputs: [
                {
                    name: "Table",
                    type: "string",
                    // FIXME: need a file picker on this one!
                    //tags: ["file"],
                },
                { name: "Key", type: "string" },
                { name: "IfNotFound", type: "string" },
                { name: "MatchPart?", type: "bool" },
            ],
            outputs: [{ name: "found", type: "string" }],
            /**
             * @param {string} table
             * @param {string} key
             * @param {string} ifNotFound
             * @param {boolean} matchPart
             * @returns {string}
             */
            impl(table, key, ifNotFound, matchPart) {
                try {
                    const tablePath = path.join(getTablesDirForDb(db.pathName), `${table}.json`);
                    let map = tableFileStore.get(tablePath);
                    if (map === undefined) {
                        // TODO: async user func
                        /** @type {string[][]} */
                        const jsonContent = JSON.parse(fs.readFileSync(tablePath, "utf8"));
                        map = new Map(jsonContent
                            .filter(row => row && (row[0] || row[1]))
                            .map((row) => [row[0] ?? "", row[1] ?? ""])
                        );
                        tableFileStore.set(tablePath, map);
                    }
                    if (matchPart) {
                        for (const entry of map) {
                            if (key.toLowerCase().includes(entry[0].toLowerCase())) {
                                return entry[1];
                            }
                        }
                        return ifNotFound;
                    } else {
                        return map.get(key) ?? ifNotFound;
                    }
                } catch (err) {
                    console.error(err);
                    throw err;
                }
            }
        },
        "JavaScriptEval": {
            inputs: [
                // TODO: need tooltips/descriptions of inputs
                { name: "Element", type: "u64" },
                { name: "Code", type: "string" },
            ],
            outputs: [
                { name: "JsonResult", type: "string" },
            ],
            /**
             * @param {bigint} elemIdNum
             * @param {string} code
             */
            impl: (elemIdNum, code) => {
                const elemId = elemIdNum === 0n ? "0" : `0x${elemIdNum.toString(16)}`;
                const element = elemId !== "0" ? db.elements.tryGetElement(elemId) : undefined;

                const evalCtx = vm.createContext({
                    core: {
                        backend: coreBackend,
                        common: coreCommon,
                        bentley: coreBentley,
                    },
                    imodel: db,
                    element,
                    console,
                });

                let evalResult;
                try {
                    evalResult = vm.runInContext(code, evalCtx);
                } catch (_err) {
                    /** @type {any} */
                    const err = _err;
                    console.error("Graphl JavaScript-Eval Error:");
                    console.error(err);
                    return JSON.stringify({ jsError: "code threw error", error: { message: err.message, stack: err.stack } });
                }

                try {
                    return JSON.stringify(evalResult);
                } catch (_err) {
                    /** @type {any} */
                    const err = _err;
                    console.error("Graphl JavaScript-Eval Error: couldn't convert expression result to JSON");
                    console.error(err);
                    return JSON.stringify({ jsError: "couldn't convert expression result to JSON", error: { message: err.message, stack: err.stack } });
                }
            },
        },

        // TODO: make memoization optional?
        BlenderProcessMesh: {
            inputs: [
              {
                name: "geometry",
                type: "extern",
                description: "The geometry to process",
              },
              {
                name: "BlenderPath",
                type: "string",
                description:
                  'Defaults to "blender" if empty.'
                  + 'Can be a full path to the exe or a name to look for in PATH'
              },
              {
                name: "ScriptPath",
                type: "string",
                description: "Path to a blender script to mutate the blender scene"
              },
            ],
            // FIXME: unify the Web IDE and compiler types
            //tags: ["blender", "geometry"],
            outputs: [{ name: "", type: "extern" }],
            //description: "Send the geometry through a local blender installation with a script to edit the geometry",
            /**
             * @param {coreBackend.ExportGraphicsMesh | Promise<coreBackend.ExportGraphicsMesh>} data // TODO: somehow do opaque JS externals in graphl?
             * @param {string} blenderPath
             * @param {string} scriptPath
             */
            impl(data, blenderPath, scriptPath) {
              return data;
            },
        },
    };

    const program = await compileGraphltSourceAndInstantiateProgram(`
      (import BlenderProcessMesh "host/BlenderProcessMesh")
      (import JavaScriptEval "host/JavaScriptEval")
      (import MapByTable "host/MapByTable")
      (import StringToU64 "host/StringToU64")
      (import NoClusterId "host/NoClusterId")
      (import MetaClusterId "host/MetaClusterId")
      (import CaselessMatch "host/CaselessMatch")
      (import UserLabel "host/UserLabel")
      (import Parent "host/Parent")
      (import Category "host/Category")
      (import ProjectCenter "host/ProjectCenter")
      (import VisibleInViewport "host/VisibleInViewport")

      (typeof (processScene) (vec3))
      (define (processScene) (begin (return (negate (ProjectCenter)))))
      (typeof (processInstance u64
                               u64
                               extern
                               vec3
                               vec3
                               u64
                               i32
                               i32
                               u64
                               string
                               rgba)
              (string u64
                      string
                      extern))
      (define (processInstance ElementId
                               GeometrySourceId
                               Geometry
                               Origin
                               Rotation
                               AnimationBatchId
                               InstanceCount
                               VertexCount
                               MaterialId
                               MaterialName
                               BasicColor)
              (begin 
                     <!__label1
                     (BlenderProcessMesh Geometry
                                         ""
                                         "/home/mike/projects/itwin-unreal-2/blender-interop/sample-scripts/decimate_0_16.py")
                     (return "imodel"
                             (NoClusterId)
                             ""
                             #!__label1)))
      (typeof (ignoreInstance u64
                              u64
                              extern
                              vec3
                              vec3
                              u64
                              i32
                              i32
                              u64
                              string
                              rgba)
              (bool))
      (define (ignoreInstance ElementId
                              GeometrySourceId
                              Geometry
                              Origin
                              Rotation
                              AnimationBatchId
                              InstanceCount
                              VertexCount
                              MaterialId
                              MaterialName
                              BasicColor)
              (begin (return #f)))
    `, graphlHostEnv);

    assert.partialDeepStrictEqual(
      program.functions.processInstance(
        1n,                            // ElementId
        2n,                            // GeometrySourceId
        new Uint8Array([0, 1, 2, 3]),  // Geometry
        {x: 0, y: 0, z: 0},            // Origin
        {x: 1, y: 1, z: 1},            // Rotation
        3n,                            // AnimationBatchId
        5,                             // InstanceCount
        6,                             // VertexCount
        7n,                            // MaterialId
        "material",                    // MaterialName
        1024,                          // BasicColor
      ),
      {
        0: "imodel",
        1: 0n,
        2: "",
        3: new Uint8Array([0,1,2,3]),
      },
    );
  });
});
