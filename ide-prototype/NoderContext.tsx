import React from "react";
import initLangLogic from "../lang-lib/zig-out/bin/graph-lang.wasm?init";
import { makeWasmHelper } from "./wasm";

// FIXME: show loading
const langLib = await initLangLogic();

export const NoderContext = React.createContext({
  noder: langLib,
});

globalThis._noder = langLib;
globalThis._noderHelper = makeWasmHelper(langLib);
