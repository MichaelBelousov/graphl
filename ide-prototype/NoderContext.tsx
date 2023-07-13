import React from "react";
import initLangLogic from "../temp-rest-api/zig-out/bin/graph-lang.wasm?init";

// FIXME: show loading
const langLib = await initLangLogic();

export const NoderContext = React.createContext({
  noder: langLib,
});

globalThis._noder = langLib;
