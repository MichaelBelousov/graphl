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

interface NoderContextType {
  langLib: WebAssembly.Instance;
  wasmUtils: ReturnType<typeof makeWasmHelper>;
  sourceDefinesToNodeTypes(source: string): string;
  lastNodeTypes: any;
}

const defaultContext: NoderContextType = {
  langLib,
  wasmUtils,
  sourceDefinesToNodeTypes,
  lastNodeTypes: {},
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

