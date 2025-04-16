// TODO: add a compiler levelJS SDK to orchestrate calls like this

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

export namespace GraphlTypes {
    export const i32: GraphlType = {
        name: "i32",
        kind: "primitive",
        size: 4,
    };

    export const f64: GraphlType = {
        name: "f64",
        kind: "primitive",
        size: 8,
    };

    export const string: GraphlType = {
        name: "string",
        kind: "primitive",
        size: 4, // FIXME: true only for wasm32
    };

    // TODO: generate these from graphl, possibly even parse them out
    // of graphl output
    export const vec3: GraphlType = {
        name: "vec3",
        kind: "struct",
        size: 24,
        fieldNames: ["x", "y", "z"],
        fieldTypes: [f64, f64, f64],
        fieldOffsets: [0, 8, 16],
    }
};

export interface UserFuncInput {
    type: GraphlType;
}

export interface UserFuncOutput {
    type: GraphlType;
}

function writeJsValueForGraphl<JsVal extends number | object>(jsVal: JsVal, view: DataView, offset: number, graphlType: GraphlType) {
    if (graphlType === GraphlTypes.f64) {
        if (typeof jsVal !== "number") {
            const err = Error(`jsVal '${JSON.stringify(jsVal)}' was not a valid f64`);
            // TODO: store the property path for better error
            // @ts-ignore
            err.code = "EBADJSVAL-f64";
            // @ts-ignore
            err.badValue = jsVal;
            throw err;
        }
        console.log("writing f64", jsVal, "to", view.byteOffset + offset);
        view.setFloat64(offset, jsVal, true);
    } else if (graphlType === GraphlTypes.i32) {
        if (typeof jsVal !== "number" || jsVal > 2**31 - 1 || jsVal < -(2**31) || Math.round(jsVal) !== jsVal) {
            const err = Error(`jsVal '${JSON.stringify(jsVal)}' was not a valid i32`);
            // @ts-ignore
            err.code = "EBADJSVAL-i32";
            // @ts-ignore
            err.badValue = jsVal;
            throw err;
        }
        view.setInt32(offset, jsVal, true);
        console.log("writing i32", jsVal, "to", view.byteOffset + offset);
    } else if (graphlType.kind === "struct") {
        for (let i = 0; i < graphlType.fieldNames.length; ++i) {
            const fieldName = graphlType.fieldNames[i];
            const fieldType = graphlType.fieldTypes[i];
            const fieldOffset = graphlType.fieldOffsets[i];
            writeJsValueForGraphl(jsVal[fieldName], view, offset + fieldOffset, fieldType)
        }
    }
}

function graphlPrimitiveValToJsVal(
    graphlVal: number,
    graphlType: GraphlType,
    wasm: WasmInstance,
): any {
    if (graphlType === GraphlTypes.f64) {
        return graphlVal
    } else if (graphlType === GraphlTypes.i32) {
        return graphlVal;
    } else if (graphlType === GraphlTypes.string) {
        // TODO: deduplicate with other exact same usage
        // FIXME: use streaming Decoder
        const textDecoder = new TextDecoder();
        let offset = 0;
        const chunks = [] as Uint8Array[];

        while (true) {
            const bytesWrittenCount = wasm.exports.__graphl_host_copy(graphlVal, offset);
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
    }
}


function graphlValToJsVal(
    graphlVal: number,
    graphlType: GraphlType,
    wasm: WasmInstance,
): any {
    if (graphlType.kind === "primitive") {
        return graphlPrimitiveValToJsVal(graphlVal, graphlType, wasm)
    } else if (graphlType.kind === "struct") {
        throw Error("unimplemented");
        const val = {};
        for (let i = 0; i < graphlType.fieldNames.length; ++i) {
            const fieldName = graphlType.fieldNames[i];
            const fieldType = graphlType.fieldTypes[i];
            const fieldOffset = graphlType.fieldOffsets[i];
        }
    }
}

const TRANSFER_BUF_PTR = 1024;

type WasmInstance = WebAssembly.Instance & {
    exports: {
        memory: WebAssembly.Memory;
        __graphl_host_copy(str: any, offset: number): number;
    },
};

type UserFuncCollection = Map<number, Function>;

function makeCallUserFunc(
    inputs: UserFuncInput[],
    outputs: UserFuncOutput[],
    wasm: WasmInstance,
    userFuncs: UserFuncCollection
): [string, Function] {
    const key = ["callUserFunc", ...inputs.map(i => i.type.name), "R", ...outputs.map(o => o.type.name)].join("_");
    const firstArgIsReturnPtr = outputs.length > 0 || outputs[0].type.kind === "struct";

    return [
        key,
        (funcId: number, ...abiParams: any[]) => {
            const userFunc = userFuncs.get(funcId);
            if (!userFunc) throw Error(`No user function with id ${funcId}, this is a bug`);

            const paramsToJs = (params: any[]): any[] => {
                const jsParams = [] as any[];

                for (let i = 0; i < params.length; ++i) {
                    const paramWasmVal = params[0];
                    const paramType = inputs[0].type;
                    if (paramType === GraphlTypes.string) {
                        // FIXME: use streaming decoder
                        const textDecoder = new TextDecoder();
                        let offset = 0;
                        const chunks = [] as Uint8Array[];

                        while (true) {
                            const bytesWrittenCount = wasm.exports.__graphl_host_copy(paramWasmVal, offset);
                            if (bytesWrittenCount === 0) break;
                            offset += bytesWrittenCount;
                            const chunk = new Uint8Array(wasm.exports.memory.buffer, TRANSFER_BUF_PTR, bytesWrittenCount);
                            chunks.push(chunk);
                            //textDecoder.writable.getWriter().write(chunk);
                            //textDecoder.readable.getReader().read();
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

                        const jsVal = textDecoder.decode(fullData);
                        jsParams.push(jsVal);
                    } else if (paramType.kind === "primitive") {
                        jsParams.push(paramWasmVal);
                    } else {
                        throw Error("struct params not implemented yet");
                        // const jsVal = {};
                        // for (let i = 0; i < paramType.fieldNames.length; ++i) {
                        //     const fieldType = paramType.fieldTypes[i];
                        //     const fieldName = paramType.fieldNames[i];
                        //     const fieldOffset = paramType.fieldOffsets[i];
                        // }
                    }
                }

                return jsParams;
            };

            if (firstArgIsReturnPtr && outputs[0].type.kind === "struct") {
                const returnPtr = abiParams[0];
                const jsParams = paramsToJs(abiParams.slice(1));
                const jsRes = userFunc.call(undefined, jsParams);
                const resultView = new DataView(wasm.exports.memory.buffer, returnPtr, outputs[0].type.size);
                writeJsValueForGraphl(jsRes, resultView, 0, outputs[0].type);
                return;
            } else if (!firstArgIsReturnPtr) {
                const jsParams = paramsToJs(abiParams);
                const jsRes = userFunc.call(undefined, jsParams);
                // TODO: if it's a string, we need to marshal it through the transfer buffer
                if (typeof jsRes === "string")
                    throw Error("Unimplemented string return type");
                if (typeof jsRes !== "number")
                    throw Error("Unimplemented return type");
                return jsRes;
            }
        }
    ];
}

export interface UserFuncDesc<F extends (...args: any[]) => any>{
    name: string;
    inputs?: UserFuncInput[],
    outputs?: UserFuncOutput[],
    impl?: F,
}

export interface GraphlProgram<Funcs extends Record<string, (...args: any[]) => any>> {
    functions: Funcs
}

export async function instantiateProgramFromWasmBuffer<Funcs extends Record<string, (...args: any[]) => any>>(
    data: ArrayBufferLike,
    hostEnv: Record<string, UserFuncDesc<Funcs[string]>> = {},
): Promise<GraphlProgram<Funcs>> {
    // need a level of indirection unfortunately (TBD if this works if we need the imports at instantiation)
    const wasmExports = { exports: undefined as any };

    const userFuncs = new Map<number, Function>() ;
    for (const [_name, userFuncDesc] of Object.entries(hostEnv ?? {})) {
        userFuncs.set(userFuncs.size, userFuncDesc.impl ?? (() => {}));
    }

    const imports = {
        env: {
            ...Object.fromEntries([
                makeCallUserFunc([], [{ type: GraphlTypes.vec3 }], wasmExports, userFuncs),
            ]),
            log_f64(f: number) {
                console.log("f64: ", f);
            },
            log_i32(f: number) {
                console.log("i32: ", f);
            },
        },
    };
    const wasm = await WebAssembly.instantiate(data, imports);
    wasmExports.exports = wasm.instance.exports;

    // FIXME: this is a hardcoded hack
    const functionOutputs = new Map<string, UserFuncOutput[]>;
    functionOutputs.set("processInstance", [{ type: GraphlTypes.string }]);

    return {
        // FIXME:
        functions: Object.fromEntries(
            Object.entries(wasm.instance.exports)
            .filter(([_key, graphlFunc]) => typeof graphlFunc === "function")
            .map(([key, graphlFunc]) => [key, (...args: any[]) => {
                    // TODO: dedup with logic in makeCallUserFunc
                    const graphlRes = (graphlFunc as Function)(...args);
                    return graphlValToJsVal(graphlRes, functionOutputs.get(key)![0].type, wasmExports);
                }
            ])
        ) as any
    };
}

export async function compileGraphltSourceAndInstantiateProgram<Funcs extends Record<string, (...args: any[]) => any>>(
    source: string,
    hostEnv: Record<string, UserFuncDesc<Funcs[string]>> = {},
): Promise<GraphlProgram<Funcs>> {
    await import("bun-zigar");
    const zig = await import("./zig/js.zig");
    console.log(zig)
    let compiledWasm;
    try {
        compiledWasm = zig.compileSource("unknown", source, undefined);
    } catch (err) {
        // TODO: handle diagnostic
        throw err;
    }
    return instantiateProgramFromWasmBuffer(compiledWasm.buffer, hostEnv);
}
