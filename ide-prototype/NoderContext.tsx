import React from "react";
import initLangLogic from "../lang-lib/zig-out/bin/graph-lang.wasm?init";
import { makeWasmHelper } from "./wasm";
import { useStable } from "@bentley/react-hooks";

// FIXME: show loading
const langLib = await initLangLogic() as WebAssembly.Instance;
const wasmUtils = makeWasmHelper(langLib);

globalThis._noder = langLib;
globalThis._wasmUtils = wasmUtils;

/** caller must free the result */
function sourceDefinesToNodeTypes(source: string) {
  const marshalledSrc = wasmUtils.marshalString(source);
  const resultPtr = langLib.exports.readSrc(marshalledSrc.ptr);
  const result = wasmUtils.ptrToStr(resultPtr);
  const { value } = result;
  result.free();
  marshalledSrc.free();
  return value;
}

type Value = number | string | boolean | { symbol: string };

type Type =
  | "num"
  | "string"
  | "exec"
  | "bool"
  | "i32" | "i64" | "f32" | "f64" | "u32" | "u64"
  | { enum: Value[] }
  | { union: string[] }
  | { struct: Record<string, string> }
  | "ptr-to-opaque";

const defaultTypes: Record<string, Type> = {
  "num": "num",
  "string": "string",
  "exec": "exec",
  "bool": "bool",
  "i32" : "i32" ,
  "i64" : "i64" ,
  "f32" : "f32" ,
  "f64" : "f64" ,
  "u32" : "u32" ,
  "u64": "u64",
  // FIXME: fake ue types
  "actor": "ptr-to-opaque",
  "vector": { struct: { x: "f32", y: "f32", z: "f32" }},
  "drone-state": { enum: [{ symbol: "move-up" }, { symbol: "move-to-player" }, { symbol: "dead" }] },
  "trace-channels": { enum: [{ symbol: "visibility" }, { symbol: "collision" }] },
  "draw-debug-types": { enum: [{ symbol: "none" }, { symbol: "line" }, { symbol: "arrow" }] },
};

interface NoderContextType {
  langLib: WebAssembly.Instance;
  wasmUtils: ReturnType<typeof makeWasmHelper>;
  sourceDefinesToNodeTypes(source: string): string;
  // TODO: move mutating state into their own hooks
  lastNodeTypes: any;
  lastFunctionDefs: {
    [name: string]: {
      variables: string[];
    }
  },
  lastTypeDefs: { [name: string]: Type };
  lastVarDefs: { [name: string]: Type };
}

const defaultContext: NoderContextType = {
  langLib,
  wasmUtils,
  sourceDefinesToNodeTypes,
  lastNodeTypes: {},
  lastFunctionDefs: {},
  lastVarDefs: {},
  lastTypeDefs: defaultTypes
};

export const NoderContext = React.createContext<NoderContextType>(defaultContext);

export const NoderProvider = (props: React.PropsWithChildren<{}>) => {
  const [lastNodeTypes, setLastNodeTypes] = React.useState({});

  const sourceDefinesToNodeTypes = useStable(() => (s: string) => {
    const result = defaultContext.sourceDefinesToNodeTypes(s);
    try {
      setLastNodeTypes(JSON.parse(result));
    } catch (error) {
      console.log(error);
      alert(error);
    }
    return result;
  });

  return <NoderContext.Provider value={{
    ...defaultContext,
    sourceDefinesToNodeTypes,
    lastNodeTypes,
  }}>
    {props.children}
  </NoderContext.Provider>
};

