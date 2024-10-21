import React from "react";
// FIXME: show loading

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
