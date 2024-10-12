import React from "react";
// FIXME: show loading

declare module "../lang-lib/src/main.zig" {
    export function x(): number;
}

import native from "../lang-lib/src/main.zig";

import { useStable } from "@bentley/react-hooks";

/** caller must free the result */
async function updateNodeTypesFromSource(source: string): Promise<string> {
  const result = await native.readSrc(source);
  // TODO: use types from zigar
  return result.string;
}

export type Value = number | string | boolean | { symbol: string };

// TODO: make always an object type with some builtin type ids
export type Type =
  | "void"
  | "num"
  | "string"
  | "exec"
  | "bool"
  | "i32" | "i64" | "f32" | "f64" | "u32" | "u64"
  | { name: string; enum: Value[] }
  | { name: string; union: string[] }
  | { name: string; struct: Record<string, string> }
  | "ptr-to-opaque";

// TODO: make a function that returns this from zig
export const defaultTypes: Record<string, Type> = {
  "void": "void",
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
  "vector": { name: "vector", struct: { x: "f32", y: "f32", z: "f32" }},
  "drone-state": { name: "drone-state", enum: [{ symbol: "move-up" }, { symbol: "move-to-player" }, { symbol: "dead" }] },
  "trace-channels": { name: "trace-channels", enum: [{ symbol: "visibility" }, { symbol: "collision" }] },
  "draw-debug-types": { name: "draw-debug-types", enum: [{ symbol: "none" }, { symbol: "line" }, { symbol: "arrow" }] },
};


export interface Variable {
  name: string;
  type: Type;
  initial: Value;
  comment: string | undefined;
}

export interface Function {
  name: string;
  params: Variable[],
  return: Type;
  comment: string | undefined;
}

interface NoderContextType {
  updateNodeTypesFromSource(source: string): Promise<string>;
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
  updateNodeTypesFromSource,
  lastNodeTypes: {},
  lastFunctionDefs: {},
  lastVarDefs: {},
  lastTypeDefs: defaultTypes
};

export const NoderContext = React.createContext<NoderContextType>(defaultContext);

export const NoderProvider = (props: React.PropsWithChildren<{}>) => {
  const [lastNodeTypes, setLastNodeTypes] = React.useState({});

  const updateNodeTypesFromSource = useStable(() => async (s: string) => {
    const result = await defaultContext.updateNodeTypesFromSource(s);
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
    updateNodeTypesFromSource,
    lastNodeTypes,
  }}>
    {props.children}
  </NoderContext.Provider>
};

