import React from "react";
import initLangLogic from "../lang-lib/zig-out/bin/graph-lang.wasm?init";
import { makeWasmHelper } from "./wasm";

// FIXME: show loading
const langLib = await initLangLogic() as WebAssembly.Instance;

globalThis._noder = langLib;
globalThis._noderHelper = makeWasmHelper(langLib);

export const NoderContext = React.createContext({
  noder: langLib,
  wasmUtils: makeWasmHelper(langLib),
});
