import React, { useEffect, useRef, useState } from "react";
import * as monaco from "monaco-editor/esm/vs/editor/editor.api"
import styles from "./Ide.module.css"
import sharedStyles from "./shared.module.css";
import { persistentData } from "./AppPersistentState";
import { Variable, Function, Type, defaultTypes } from "./NoderContext";
import debounce from "lodash.debounce";

export const TextEditor = function TextEditor(props: TextEditor.Props) {
  const monacoElem = useRef<HTMLDivElement>(null);

  const [_editorProgram, setEditorProgram] = useState(persistentData.editorProgram);

  /*
  // TODO: sync better instead of this
  const debouncedUpdateNodeTypesFromSource = React.useMemo(() => debounce(noder.updateNodeTypesFromSource, 200), [noder.updateNodeTypesFromSource]);

  useEffect(() => {
    // TODO: do in a worker probably
    debouncedUpdateNodeTypesFromSource(editorProgram);
  }, [editorProgram, debouncedUpdateNodeTypesFromSource]);
  */

  useEffect(() => {
    if (monacoElem.current) {
      props.editor.set((editor) => {
        const result = editor ?? monaco.editor.create(monacoElem.current!, {
          value: persistentData.editorProgram,
          language: "scheme",
          theme: "vs-dark",
        })
        result.onDidChangeModelContent(() => {
          setEditorProgram(result.getValue());
          persistentData.editorProgram = result.getValue()
          props.onSyncSource?.(result.getValue());
        });
        globalThis._monacoSyncHook = (msg: string) => {
          result.getModel()?.setValue(msg);
        };
        return result;
      });
    }
  }, [monacoElem.current]);

  return <div className={styles.textEditor} ref={monacoElem} />
};

interface GetSet<T> {
  value: T;
  set: React.Dispatch<React.SetStateAction<T>>;
}

namespace TextEditor {
  export interface Props {
    onSyncSource: (source: string) => Promise<void>;
    editor: GetSet<monaco.editor.IStandaloneCodeEditor | null>;
  }
}

interface ProgramContext {
  // TODO: consolidate into one mapping to prevent collisions
  variables: GetSet<Record<string, Variable>>;
  functions: GetSet<Record<string, Function>>;
  // TODO: rename to defined types?
  types: GetSet<Record<string, Type>>;
}

const ProgramContext = React.createContext(new Proxy({} as ProgramContext, {
  get() { throw new Error("accessed ProgramContext outside of provider"); }
}))

type DeclType = keyof ProgramContext;

const typeName = (t: Type) => typeof t === "string" ? t : t.name;

function TypeSelect(props: { getset: GetSet<Type> } & React.HTMLProps<HTMLSelectElement>) {
  const progCtx = React.useContext(ProgramContext);

  const allTypes = React.useMemo(() => ({
    ...defaultTypes,
    ...progCtx.types.value,
  }), [progCtx.types.value]);

  const allTypeList = React.useMemo(() => [
    ...Object.values(allTypes),
  ], [allTypes]);

  return (
    <select
      {...props}
      value={typeName(props.getset.value)}
      onChange={e => props.getset.set(allTypes[e.currentTarget.value])}
    >
      {allTypeList.map(t => (
        <option value={typeName(t)}>{typeName(t)}</option>
      ))}
    </select>
  )
}

// TODO: React.memo to ignore changes to initialValue
const NameInput = React.forwardRef<HTMLInputElement | null, { initialValue: string, onChange: (s: string) => void}>((props, ref) => {
  const nameInputRef = React.useRef<HTMLInputElement>(null);

  const firstRender = React.useRef(true);

  React.useEffect(() => {
    if (firstRender.current) {
      nameInputRef.current?.select();
      firstRender.current = false;
    }
  }, []);

  React.useLayoutEffect(() => {
    if (nameInputRef.current !== null) {
      nameInputRef.current.value = props.initialValue;
    }
  }, []);

  // FIXME: is this right?
  React.useImperativeHandle(ref, () => nameInputRef.current as any, [nameInputRef.current]);

  return (
    <input
      ref={nameInputRef}
      className={`${sharedStyles.transparentInput} ${styles.nameInput}`}
      onKeyDown={e => {
        if (e.key === "Enter") {
          e.currentTarget.blur();
          return false;
        }
      }}
      onBlur={e => {
        const val = e.currentTarget.value;
        if (val.length > 0)
          props.onChange(val);
        else
          e.currentTarget.focus();
      }}
    />
  );
});

export function Ide(_props: Ide.Props) {
  const [editor, setEditor] = useState<monaco.editor.IStandaloneCodeEditor | null>(null);
  const getsetEditor = React.useMemo(() => ({ value: editor, set: setEditor }), [editor, setEditor]);

  const [variables, setVariables] = React.useState({} as Record<string, Variable>);
  const [functions, setFunctions] = React.useState({} as Record<string, Function>);
  const [types, setTypes] = React.useState({} as Record<string, Type>);

  const programContext: ProgramContext = React.useMemo(() => ({
    variables: {
      value: variables,
      set: setVariables,
    },
    functions: {
      value: functions,
      set: setFunctions,
    },
    types: {
      value: types,
      set: setTypes,
    },
  }), [variables, functions, setVariables, setFunctions, types, setTypes]);

  return (
    <ProgramContext.Provider value={programContext}>
      <div className={styles.ide}>
        <TextEditor onSyncSource={async () => {}} editor={getsetEditor} />
      </div>
    </ProgramContext.Provider>
  );
}

namespace Ide {
  export interface Props {}
}

export default Ide;
