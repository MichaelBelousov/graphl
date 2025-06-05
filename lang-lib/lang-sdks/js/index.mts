
// load compiler wasm lazily since not all users need it (e.g. the IDE)

/** @type {undefined | Promise<import("./zig/js.zig")>} */
let _zigPromise = undefined;

const getZig = () => {
    return _zigPromise ??= (async () => {
        // @ts-ignore
        await import("node-zigar/cjs");
        const imported: any =
            (globalThis as any)._GRAPHL_JS_NATIVE
            ? require("./js.zigar") // FIXME: need a require for rollup here, but I think need await import to run tests in node
            : await import("./zig/js.zig");
        const inNodeJs = typeof process !== "undefined";
        if (inNodeJs) {
            const { WASI } = await import("node:wasi");
            const wasi = new WASI({
                version: "preview1",
                env: {},
                args: [],
            });
            // @ts-ignore
            await imported.__zigar.init(wasi);
        } else {
            await imported.__zigar.init();
        }
        return imported;
    })();
};

export type GraphlType =
    | {
      name: string;
      kind: "primitive";
      size: number;
    }
    | {
      name: string;
      kind: "struct";
      size: number;
      fieldNames: string[];
      fieldTypes: GraphlType[];
      fieldOffsets: number[];
    }
    // | {
    //   name: string;
    //   kind: "heap-array";
    //   size: number;
    // }
    // | {
    //   name: string;
    //   kind: "heap-struct";
    //   size: number;
    // }
;

// TODO: rename to like BuiltinTypes cuz doesn't include user defined types
export namespace GraphlTypes {
    export const void_: GraphlType = { name: "void", kind: "primitive", size: 0 };
    export const i32: GraphlType = { name: "i32", kind: "primitive", size: 4 };
    export const u32: GraphlType = { name: "u32", kind: "primitive", size: 4 };
    export const i64: GraphlType = { name: "i64", kind: "primitive", size: 8 };
    export const u64: GraphlType = { name: "u64", kind: "primitive", size: 8 };
    export const bool: GraphlType = { name: "bool", kind: "primitive", size: 4 };
    export const f32: GraphlType = { name: "f32", kind: "primitive", size: 4 };
    export const f64: GraphlType = { name: "f64", kind: "primitive", size: 8 };
    // FIXME: is this really a primtive? bad name
    export const string: GraphlType = { name: "string", kind: "primitive", size: 0 };
    export const code: GraphlType = { name: "string", kind: "primitive", size: 0 };
    export const rgba: GraphlType = { name: "rgba", kind: "primitive", size: 4 };

    // TODO: parse structs out of graphl meta section
    // of graphl output
    export const vec3: GraphlType = {
        name: "vec3",
        kind: "struct",
        size: 24,
        fieldNames: ["x", "y", "z"],
        fieldTypes: [f64, f64, f64],
        fieldOffsets: [0, 8, 16],
    };
};

function assert(condition: any, message?: string): asserts condition {
    if (!condition) throw Error(message ?? "assertion condition was false");
}

function typeFromTypeArray(name: string, types: GraphlType[]): GraphlType {
    if (types.length === 0) return GraphlTypes.void_;
    if (types.length === 1) return types[0];

    let offset = 0;
    const fieldOffsets = [] as number[];
    for (const graphlType of types) {
        fieldOffsets.push(offset);
        offset += graphlType.size;
    }

    return {
        name,
        kind: "struct",
        fieldNames: types.map((_, i) => String(i)),
        fieldTypes: types,
        fieldOffsets,
        size: offset,
    };
}

// FIXME: use keyof GraphlTypes?
type GraphlTypeKey = "string" | "vec3" | "i32" | "u64" | "bool" | "f64" | "rgba" | "i64" | "u32" | "code";

export interface UserFuncInput {
    name?: string;
    type: GraphlType | GraphlTypeKey;
    description?: string;
}

function inputToType(input: UserFuncInput, ctx: GraphlContext): GraphlType {
    return typeof input.type === "string" ? ctx.types[input.type] : input.type;
}

export interface UserFuncOutput {
    name?: string;
    type: GraphlType | GraphlTypeKey;
}

function outputToType(output: UserFuncOutput, ctx: GraphlContext): GraphlType {
    return typeof output.type === "string" ? ctx.types[output.type] : output.type;
}

function jsValToGraphlPrimitiveVal(
    jsVal: number | bigint | string | boolean,
    graphlType: GraphlType,
    wasm: WasmInstance,
): bigint | number | WasmHeapType {
    if (graphlType === GraphlTypes.string) {
        assert(typeof jsVal === "string");

        // FIXME: use streaming Encoder and encode into memory directly
        const fullData = new TextEncoder().encode(jsVal);
        let offset = 0;

        const graphlString = wasm.exports.__graphl_create_array_string(fullData.byteLength);

        while (offset < fullData.byteLength) {
            const chunk = fullData.slice(offset, offset + TRANSFER_BUF_LEN)
            getTransferBufUint8Array(wasm).set(chunk);
            wasm.exports.__graphl_read_array(graphlString, offset, chunk.byteLength);
            offset += TRANSFER_BUF_LEN;
        }

        return graphlString;
    } else if (graphlType === GraphlTypes.bool) {
        return jsVal ? 1 : 0;
    } else {
        return jsVal;
    }
}

function jsValToGraphlStructVal(
    jsVal: any,
    graphlType: GraphlType,
    wasm: WasmInstance,
): any {
    if (graphlNativeValSym in jsVal)
        return jsVal[graphlNativeValSym];

    const arraySlotQueue = [] as { fullData: Uint8Array }[];

    function jsValToGraphlStructMem(jsVal: any, subStructType: GraphlType, offset: number) {
        assert(subStructType.kind === "struct");
        const transferBufView = new DataView(wasm.exports.memory.buffer, TRANSFER_BUF_PTR, TRANSFER_BUF_LEN);

        for (let i = 0; i < subStructType.fieldNames.length; ++i) {
            const fieldName = subStructType.fieldNames[i];
            const fieldType = subStructType.fieldTypes[i];
            const fieldOffset = subStructType.fieldOffsets[i];
            const fieldValue = jsVal[fieldName];

            if (fieldType === GraphlTypes.f32) {
                assert(
                    typeof fieldValue === "number",
                    `received non-number value '${JSON.stringify(fieldValue)}' for field '${fieldName}' of struct ${fieldType.name}`,
                );
                transferBufView.setFloat32(offset, fieldValue, true);

            } else if (fieldType === GraphlTypes.f64) {
                assert(
                    typeof fieldValue === "number",
                    `received non-number value '${JSON.stringify(fieldValue)}' for field '${fieldName}' of struct ${fieldType.name}`,
                );
                transferBufView.setFloat64(offset, fieldValue, true);

                // TODO: support struct format for rgba
            } else if (fieldType === GraphlTypes.i32 || fieldType === GraphlTypes.rgba) {
                assert(
                    // TODO: support bigint?
                    typeof fieldValue === "number" && fieldValue >= -(2**31) && fieldValue <= 2**31-1 && Math.round(fieldValue) === fieldValue,
                    `received value '${JSON.stringify(fieldValue)}' that was not a 32-bit signed integer for field '${fieldName}' of struct ${fieldType.name}`,
                );
                transferBufView.setInt32(offset, fieldValue, true);

            } else if (fieldType === GraphlTypes.i64) {
                assert(
                    (typeof fieldValue === "number" && fieldValue >= Number.MIN_SAFE_INTEGER && fieldValue <= Number.MAX_SAFE_INTEGER && Math.round(fieldValue) === fieldValue)
                    || (typeof fieldValue === "bigint" && fieldValue >= /* -2**63 */ -9223372036854775808n && fieldValue <= /* 2**63-1 */ 9223372036854775807n),
                    `received value '${JSON.stringify(fieldValue)}' that was not a 64-bit signed integer for field '${fieldName}' of struct ${fieldType.name}`,
                );
                transferBufView.setBigInt64(offset, BigInt(fieldValue), true);
            } else if (fieldType === GraphlTypes.u32) {
                assert(
                    typeof fieldValue === "bigint" && fieldValue >= 0 && fieldValue <= 2**32-1,
                    `received value '${JSON.stringify(fieldValue)}' that was not a 32-bit unsigned number value for field '${fieldName}' of struct ${fieldType.name}`,
                );
                transferBufView.setBigInt64(offset, fieldValue, true);
            } else if (fieldType === GraphlTypes.u64) {
                assert(
                    (typeof fieldValue === "number" && fieldValue >= 0 && fieldValue <= Number.MAX_SAFE_INTEGER && Math.round(fieldValue) === fieldValue)
                    || (typeof fieldValue === "bigint" && fieldValue >= 0 && fieldValue <= /* 2**64-1 */ 0xffff_ffff_ffff_ffffn),
                    `received value '${JSON.stringify(fieldValue)}' that was not a 64-bit unsigned integer for field '${fieldName}' of struct ${fieldType.name}`,
                );
                transferBufView.setBigUint64(offset, BigInt(fieldValue), true);
            } else if (fieldType === GraphlTypes.bool) {
                assert(
                    typeof fieldValue === "boolean",
                    `received value '${JSON.stringify(fieldValue)}' that was not a boolean value for field '${fieldName}' of struct ${fieldType.name}`,
                );
                transferBufView.setInt32(offset, fieldValue ? 1 : 0, true);
            } else if (fieldType === GraphlTypes.string) {
                // FIXME: should write an empty usize into memory for array references, even if they aren't used yet
                assert(
                    typeof fieldValue === "string",
                    `received non-string value '${JSON.stringify(fieldValue)}' for field '${fieldName}' of struct ${fieldType.name}`,
                );
                arraySlotQueue.push({ fullData: new TextEncoder().encode(fieldValue) });
            } else if (fieldType.kind === "struct") {
                jsValToGraphlStructMem(fieldValue, fieldType, offset + fieldOffset);
            } else {
                throw Error(`unhandled field type: ${fieldType.name}`);
            }
        }
    }

    jsValToGraphlStructMem(jsVal, graphlType, 0);

    const graphlStructVal = wasm.exports[`__graphl_read_struct_${graphlType.name}_fields`]();

    {
        let i = 0;
        for (const { fullData } of arraySlotQueue) {
            let offset = 0;
            while (offset < fullData.byteLength) {
                const transferBuf = getTransferBufUint8Array(wasm);
                transferBuf.set(fullData.slice(offset));
                wasm.exports[`__graphl_read_struct_${graphlType.name}_array`](graphlStructVal, i, offset, Math.min(TRANSFER_BUF_LEN, fullData.byteLength - offset));
                offset += TRANSFER_BUF_LEN;
            }
            i += 1;
        }
    }

    return graphlStructVal;
}

function graphlPrimitiveValToJsVal(
    graphlVal: number | WasmHeapType,
    graphlType: GraphlType,
    wasm: WasmInstance,
): any {
    if (graphlType === GraphlTypes.string) {
        // TODO: deduplicate with other exact same usage
        // FIXME: use streaming Decoder
        const textDecoder = new TextDecoder();
        let offset = 0;
        const chunks = [] as Uint8Array[];

        while (true) {
            const bytesWrittenCount = wasm.exports.__graphl_write_array(graphlVal, offset);
            if (bytesWrittenCount === 0) break;
            offset += bytesWrittenCount;
            const chunk = new Uint8Array(wasm.exports.memory.buffer, TRANSFER_BUF_PTR, bytesWrittenCount);
            chunks.push(chunk);
        }

        const totalSize = offset;
        const fullData = new Uint8Array(totalSize);

        // TODO: use streaming decoder
        {
            let fullDataOffset = 0;
            for (const chunk of chunks) {
                fullData.set(chunk, fullDataOffset);
                fullDataOffset += chunk.byteLength;
            }
        }

        return textDecoder.decode(fullData);
    } else if (graphlType === GraphlTypes.bool) {
        return graphlVal ? true : false;
    } else {
        return graphlVal
    }
}

const graphlNativeValSym = Symbol.for("graphl-native-val");

function graphlStructValToJsVal(
    graphlVal: WasmHeapType,
    graphlType: GraphlType,
    wasm: WasmInstance,
): any {
    const _arrayCount = wasm.exports[`__graphl_write_struct_${graphlType.name}_fields`](graphlVal);

    const arraySlotQueue = [] as { obj: any, fieldName: string }[];

    const result: any = {};

    Object.defineProperty(result, graphlNativeValSym, {
        value: graphlVal,
        enumerable: false,
        writable: false,
        configurable: false,
    });

    function graphlStructMemToJsVal(subStructType: GraphlType, offset: number, result: any = {}) {
        assert(subStructType.kind === "struct");

        const transferBufView = new DataView(wasm.exports.memory.buffer, TRANSFER_BUF_PTR, TRANSFER_BUF_LEN);

        // FIXME: extract arrays!
        for (let i = 0; i < subStructType.fieldNames.length; ++i) {
            const fieldType = subStructType.fieldTypes[i];
            const fieldName = subStructType.fieldNames[i];
            const fieldOffset = subStructType.fieldOffsets[i];

            if (fieldType === GraphlTypes.f32) {
                result[fieldName] = transferBufView.getFloat32(fieldOffset, true);
            } else if (fieldType === GraphlTypes.f64) {
                result[fieldName] = transferBufView.getFloat64(fieldOffset, true);
            } else if (fieldType === GraphlTypes.i32 || fieldType === GraphlTypes.rgba) {
                result[fieldName] = transferBufView.getInt32(fieldOffset, true);
            } else if (fieldType === GraphlTypes.i64) {
                result[fieldName] = transferBufView.getBigInt64(fieldOffset, true);
            } else if (fieldType === GraphlTypes.u32) {
                result[fieldName] = transferBufView.getUint32(fieldOffset, true);
            } else if (fieldType === GraphlTypes.u64) {
                result[fieldName] = transferBufView.getBigUint64(fieldOffset, true);
            } else if (fieldType === GraphlTypes.bool) {
                result[fieldName] = Boolean(transferBufView.getInt32(fieldOffset, true));
            } else if (fieldType === GraphlTypes.string) {
                arraySlotQueue.push({ obj: result, fieldName })
            } else if (fieldType.kind === "struct") {
                result[fieldName] = {};
                // FIXME: bad struct val
                graphlStructMemToJsVal(fieldType, offset + fieldOffset);
            } else {
                throw Error(`unhandled field type: ${fieldType.name}`);
            }
        }


        return result;
    }

    graphlStructMemToJsVal(graphlType, 0, result);

    {
        let i = 0;
        for (const arraySlot of arraySlotQueue) {
            // FIXME: make a common function for this...
            const chunks = [] as Uint8Array[];
            let offset = 0;
            while (true) {
                const arrayLen = wasm.exports[`__graphl_write_struct_${graphlType.name}_array`](graphlVal, i, offset);
                const chunk = new Uint8Array(wasm.exports.memory.buffer, TRANSFER_BUF_PTR, arrayLen);
                chunks.push(chunk);
                if (chunk.byteLength === 0) break;
                offset += arrayLen;
            }
            const fullData = new Uint8Array(offset);
            // TODO: use streaming decoder instead
            {
                let fullDataOffset = 0;
                for (const chunk of chunks) {
                    fullData.set(chunk, fullDataOffset);
                    fullDataOffset += chunk.byteLength;
                }
            }
            arraySlot.obj[arraySlot.fieldName] = new TextDecoder().decode(fullData);
            i += 1;
        }
    }

    return result;
}

type WasmHeapType = {};

function jsValToGraphlVal(
    jsVal: any,
    graphlType: GraphlType,
    wasm: WasmInstance,
): any {
    if (graphlType.kind === "primitive") {
        return jsValToGraphlPrimitiveVal(jsVal, graphlType, wasm)
    } else if (graphlType.kind === "struct") {
        return jsValToGraphlStructVal(jsVal, graphlType, wasm);
    } else {
        throw Error("unhandled");
    }
}

function graphlValToJsVal(
    graphlVal: any,
    graphlType: GraphlType,
    wasm: WasmInstance,
): any {
    if (graphlType.kind === "primitive") {
        return graphlPrimitiveValToJsVal(graphlVal, graphlType, wasm)
    } else if (graphlType.kind === "struct") {
        return graphlStructValToJsVal(graphlVal, graphlType, wasm);
    } else {
        throw Error("unhandled");
    }
}

const TRANSFER_BUF_PTR = 1024;
// FIXME: maybe the tranfer buffer should be one wasm page size
const TRANSFER_BUF_LEN = 4096;
const getTransferBufView = (w: WasmInstance) => new DataView(w.exports.memory.buffer, TRANSFER_BUF_PTR, TRANSFER_BUF_LEN);
const getTransferBufUint8Array = (w: WasmInstance) => new Uint8Array(w.exports.memory.buffer, TRANSFER_BUF_PTR, TRANSFER_BUF_LEN);

type WasmInstance = WebAssembly.Instance & {
    exports: {
        memory: WebAssembly.Memory;
        __graphl_create_array_string(size: number): WasmHeapType;
        // FIXME: rename to include _string
        __graphl_read_array(str: WasmHeapType, offset: number, length: number): void;
        // FIXME: rename to include _string
        __graphl_write_array(str: WasmHeapType, offset: number): number;
        /**
         * writes the fields of a graphl struct into the transfer buffer
         * @returns the amount of arrays in the struct
         */
        [K: `__graphl_write_struct_${string}_fields`]: (struct: WasmHeapType) => number,
        /**
         * writes the bytes of a graphl array at the specified array slot index of a struct into the transfer buffer
         * @returns the amount of bytes written which may be the transfer buffer size meaning this should
         * be called again with a higher offset
         */
        [K: `__graphl_write_struct_${string}_array`]: (struct: WasmHeapType, arraySlotIndex: number, offset: number) => number,
        /**
         * reads the fields for a graphl struct from the transfer buffer
         */
        [K: `__graphl_read_struct_${string}_fields`]: () => WasmHeapType,
        /**
         * reads bytes from the transfer buffer for a graphl array at the spec
         */
        [K: `__graphl_read_struct_${string}_array`]: (struct: WasmHeapType, arraySlotIndex: number, offset: number, length: number) => void,
    },
};

type UserFuncCollection = Map<number, Function>;

// calls of a userfunc from graphl looks like:
// - graphl passes all inputs as arguments
// - NOTE: could be faster if there are many struct params to just write all of them
// - js must call "__graphl_write_struct_{s}_fields" and "__graphl_write_array" to read
//   struct and array params
// - js prepares its return value
// - js writes returns single primitives as a single return value
//   js writes non-primitives or multiple results as a struct into transfer memory
// - js enqueues any "arrays"
// - js returns
// - if the return was a single primitive, use it
//   if the outputs were a struct or multi, graphl reads it with "__graphl_read_struct_{s}_fields"
// - NOTE: should just write arrays in the empty space after struct members, to avoid chattyness
// - graphl calls "__graphl_write_struct_{s}_array(struct, arraySlotIndex, offset)" each time it needs an array
function makeCallUserFunc(
    inputs: UserFuncInput[],
    outputs: UserFuncOutput[],
    wasm: WasmInstance,
    userFuncs: UserFuncCollection,
    ctx: GraphlContext,
): [string, Function] {
    const key = [
        "callUserFunc",
        ...inputs.map(i => typeof i.type === "string" ? i.type : i.type.name),
        "R",
        ...outputs.map(o => typeof o.type === "string" ? o.type : o.type.name),
    ].join("_");

    return [
        key,
        (funcId: number, ...abiParams: any[]) => {
            const userFunc = userFuncs.get(funcId);
            assert(userFunc, `No user function with id ${funcId}, this is a bug`);
            const jsParams = abiParams.map((p, i) => graphlValToJsVal(
                p,
                inputToType(inputs[i], ctx),
                wasm,
            ));
            const jsRes = userFunc.call(undefined, ...jsParams);
            const returnType = typeFromTypeArray(key, outputs.map((o) => outputToType(o, ctx)));
            return jsValToGraphlVal(jsRes, returnType, wasm);
        }
    ];
}

export interface UserFuncDesc<F extends (...args: any[]) => any>{
    inputs?: UserFuncInput[],
    outputs?: UserFuncOutput[],
    impl?: F,
    kind?: "func" | "pure",
}

export interface GraphlProgram<Funcs extends Record<string, (...args: any[]) => any>> {
    functions: Funcs
    _wasmInstance: WasmInstance
}

function indexOfSubArray(haystack: DataView, needle: DataView) {
    let j = 0;

    for (let i = 0; i < haystack.byteLength; ++i) {
        if (haystack.getUint8(i) === needle.getUint8(j)) {
            j += 1
        } else {
            j = 0;
        }

        if (j >= needle.byteLength) {
            return i - needle.byteLength;
        }
    }

    return -1;
}

/**
 * TEMP: this is like really really going to change
 */
interface GraphlMeta {
    structs: {
        name: string;
        field_names: string[];
        field_types: string[];
    }[];
    functions: {
        name: string;
        // types, FIXME: use objects for extensibility (e.g. names, descriptions, etc)
        inputs: string[];
        // types
        outputs: string[];
    }[];
    host: {
        functions: {
            id: number;
            name: string;
            // types
            inputs: string[];
            // types
            outputs: string[];
        }[];
    }
}


function parseGraphlMeta(wasmBuffer: ArrayBufferLike): GraphlMeta {
    const wasmView = new DataView(wasmBuffer);

    // HACK: just parse for custom sections manually, it's not that hard!
    // SEE: https://danielmangum.com/posts/every-byte-wasm-module/
    // FIXME: fix the types here
    const graphlMetaStart = indexOfSubArray(wasmView, new DataView(new TextEncoder().encode('{"token":"63a7f259-5c6b-4206-8927-8102dc9ad34d').buffer)) + 1;
    assert(graphlMetaStart !== -1, "graphl meta token not found");

    let parenCount = 1;
    for (let i = graphlMetaStart + 1; i < wasmBuffer.byteLength; ++i) {
        // TODO: handle string literals, for now not parsing actual JSON
        if (String.fromCharCode(wasmView.getUint8(i)) === "{"
            || String.fromCharCode(wasmView.getUint8(i)) === "[")
            parenCount += 1;
        else if (String.fromCharCode(wasmView.getUint8(i)) === "}"
            || String.fromCharCode(wasmView.getUint8(i)) === "]")
            parenCount -= 1;

        if (parenCount === 0) {
            const slice = wasmBuffer.slice(graphlMetaStart, i + 1);
            const jsonSrc = new TextDecoder().decode(slice as BufferSource);
            const parsed = JSON.parse(jsonSrc);
            delete parsed.token;
            return parsed;
        }
    }

    throw Error("couldn't find end of graphl meta")
}

interface GraphlContext {
    types: Record<string, GraphlType>;
}

export async function instantiateProgramFromWasmBuffer<Funcs extends Record<string, (...args: any[]) => any>>(
    data: ArrayBufferLike,
    hostEnv: Record<string, UserFuncDesc<Funcs[string]>> = {},
): Promise<GraphlProgram<Funcs>> {
    // need a level of indirection unfortunately (TBD if this works if we need the imports at instantiation)
    const wasmExports: WasmInstance = { exports: undefined as any };

    const graphlMeta = parseGraphlMeta(data);

    const neededUserFuncs = new Map(graphlMeta.host.functions.map(f => [f.name, f.id]));
    const userFuncEnvImports: any = {};

    const userFuncs = new Map<number, Function>() ;

    const ctx: GraphlContext = {
        types: {...GraphlTypes},
    };

    const functionMap = new Map<string, {
        name: string,
        inputs: UserFuncInput[],
        outputs: UserFuncOutput[],
    }>;

    for (const struct of graphlMeta.structs) {
        const result = {
            name: struct.name,
            kind: "struct" as const,
            size: 0,
            fieldNames: struct.field_names,
            // FIXME: assumes graphl orders this (it should)
            fieldTypes: struct.field_types.map(t => ctx.types[t]),
            fieldOffsets: [] as number[],
        };

        let offset = 0;
        for (const typeName of struct.field_types) {
            result.fieldOffsets.push(offset);
            offset += ctx.types[typeName].size;
        }
        result.size = offset;
    
        ctx.types[struct.name] = result;
    }

    for (const [name, userFuncDesc] of Object.entries(hostEnv ?? {})) {
        const id = neededUserFuncs.get(name);
        // ignore unnecessary user funcs
        if (id === undefined) continue;
        userFuncs.set(id, userFuncDesc.impl ?? (() => {}));
        neededUserFuncs.delete(name);

        const [key, impl] = makeCallUserFunc(userFuncDesc.inputs ?? [], userFuncDesc.outputs ?? [], wasmExports, userFuncs, ctx);
        if (!(key in userFuncEnvImports)) {
            userFuncEnvImports[key] = impl;
        }
    }

    if (neededUserFuncs.size > 0) {
        const err = Error(`Unspecified host functions: ${[...neededUserFuncs]}`);
        (err as any).unspecifiedFunctionNames = [...neededUserFuncs];
        throw err;
    }

    for (const fn of graphlMeta.functions) {
        functionMap.set(fn.name, {
            name: fn.name,
            inputs: fn.inputs.map(i => ({ type: ctx.types[i]})),
            outputs: fn.outputs.map(o => ({ type: ctx.types[o]})),
        });
    }

    const imports = {
        // FIXME: categorize intrinsic and host-provided functions into different namespaces than "env"
        env: {
            ...userFuncEnvImports,
            __graphl_host_log_msg(...wasmArgs: any[]) {
                const graphlArgs = [];
                for (let i = 0; i < wasmArgs.length; i += 2) {
                    const typeId = wasmArgs[i];
                    const val = wasmArgs[i + 1];
                    // FIXME: convert to type correctly
                    graphlArgs.push(jsValToGraphlVal(val, GraphlTypes.i32, wasmExports));
                }
                console.log(...graphlArgs)
            }
        },
    };
    const wasm = await WebAssembly.instantiate(data, imports);
    wasmExports.exports = (wasm.instance as WasmInstance).exports;

    return {
        functions: Object.fromEntries(
            Object.entries(wasm.instance.exports)
            .filter(([_key, graphlFunc]) => typeof graphlFunc === "function")
            .map(([key, graphlFunc]) => [key, (...args: any[]) => {
                const fnInfo = functionMap.get(key)!;
                const graphlArgs = args.map((arg, i) => jsValToGraphlVal(
                    arg,
                    inputToType(fnInfo.inputs[i], ctx),
                    wasmExports,
                ));
                const graphlRes = (graphlFunc as Function)(...graphlArgs);
                if (fnInfo.outputs.length === 0)
                    return undefined;
                if (fnInfo.outputs.length === 1)
                    return graphlValToJsVal(graphlRes, outputToType(fnInfo.outputs[0], ctx), wasmExports);
                const returnType = typeFromTypeArray(key, fnInfo.outputs.map((o) => outputToType(o, ctx)));
                return graphlValToJsVal(graphlRes, returnType, wasmExports);
            }])
        ) as any,
        _wasmInstance: wasm.instance as WasmInstance,
    };
}

export async function compileGraphltSource(
  source: string,
  hostEnv: Record<string, UserFuncDesc<any>> = {},
): Promise<Uint8Array> {
    const builtinCtx: GraphlContext = {
        types: {...GraphlTypes },
    };

    const userFuncDescs = Object.fromEntries(
        Object.entries(hostEnv).map(([k, v], i) => [
            k,
            {
                id: i,
                node: {
                    name: k,
                    //hidden: false,
                    kind: v.kind,
                    inputs: v.inputs?.map((inp, j) => ({ name: `p${j}`, type: inputToType(inp, builtinCtx).name })) ?? [],
                    outputs: v.outputs?.map((out, j) => ({ name: `p${j}`, type: outputToType(out, builtinCtx).name })) ?? [],
                    tags: ["host"],
                },
            }
        ]),
    );

    const userFuncDescsJson = JSON.stringify(userFuncDescs);

    const zig = await getZig();

    let compiledWasm;
    const diagnostic = new zig.Diagnostic({});
    try {
        compiledWasm = zig.compileSource("unknown", source, userFuncDescsJson, diagnostic).typedArray;
        if (process.env.ITUE_DEBUG_DUMP)
            (await import("node:fs")).writeFileSync(process.env.ITUE_DEBUG_DUMP, compiledWasm)
    } catch (err: any) {
        // FIXME: add zigar types
        const diagStr = diagnostic.error.string;
        throw new Error(diagStr === "" || diagStr === "Not an error" ? err.message : diagStr);
    }

    return compiledWasm;
}

export async function compileGraphltSourceAndInstantiateProgram<Funcs extends Record<string, (...args: any[]) => any>>(
    source: string,
    hostEnv: Record<string, UserFuncDesc<Funcs[string]>> = {},
): Promise<GraphlProgram<Funcs>> {
    const compiledWasm = await compileGraphltSource(source, hostEnv);
    return instantiateProgramFromWasmBuffer(compiledWasm.buffer, hostEnv);
}
