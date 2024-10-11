import React, { useContext, useEffect, useRef, useState } from "react";
import TestGraphEditor from "./TestGraphEditor";
import * as monaco from "monaco-editor/esm/vs/editor/editor.api"
import styles from "./Ide.module.css"
import sharedStyles from "./shared.module.css";
import { persistentData } from "./AppPersistentState";
import { NoderContext, Variable, Function, Type } from "./NoderContext";
import debounce from "lodash.debounce";

const apiBaseUrl = "http://localhost:3001"

async function onSyncGraph(_graph: any) {
  const resp = await fetch(`${apiBaseUrl}/graph_to_source`);
  const _t = await resp.text()
}

async function onSyncSource(_source: any) {
  const resp = await fetch(`${apiBaseUrl}/source_to_graph`);
  const _t = await resp.text()
}

export function TextEditor(props: TextEditor.Props) {
  const [editor, setEditor] = useState<monaco.editor.IStandaloneCodeEditor | null>(null);
  const monacoElem = useRef<HTMLDivElement>(null);

  const [editorProgram, setEditorProgram] = useState(persistentData.editorProgram);

  const noder = useContext(NoderContext);

  const debouncedUpdateNodeTypesFromSource = React.useMemo(() => debounce(noder.updateNodeTypesFromSource, 200), [noder.updateNodeTypesFromSource]);

  // TODO: do this in a worker with cancellation cuz it's slow...
  useEffect(() => {
    debouncedUpdateNodeTypesFromSource(editorProgram);
  }, [editorProgram, debouncedUpdateNodeTypesFromSource]);

  useEffect(() => {
    if (monacoElem.current)
      setEditor((editor) => {
        const result = editor ?? monaco.editor.create(monacoElem.current!, {
          value: persistentData.editorProgram,
          language: "scheme",
          theme: "vs-dark",
        })
        result.onDidChangeModelContent(() => {
          setEditorProgram(result.getValue());
          persistentData.editorProgram = result.getValue()
        });
        return result;
      })
  }, [monacoElem.current]);
  return <div className={styles.textEditor} ref={monacoElem} />
}

namespace TextEditor {
  export interface Props {
    onSyncSource: (source: string) => Promise<void>;
  }
}

interface GetSet<T> {
  value: T;
  set: React.Dispatch<React.SetStateAction<T>>;
}

interface ProgramContext {
  // TODO: consolidate into one mapping to prevent collisions
  variables: GetSet<Record<string, Variable>>;
  functions: GetSet<Record<string, Function>>;
  types: GetSet<Record<string, Type>>;
}

const ProgramContext = React.createContext(new Proxy({} as ProgramContext, {
  get() { throw new Error("accessed not ready ProgramContext"); }
}))

type DeclType = keyof ProgramContext;

const typeName = (t: Type) => typeof t === "string" ? t : t.name;

function TypeSelect(props: { getset: GetSet<Type> } & React.HTMLProps<HTMLSelectElement>) {
  const progCtx = React.useContext(ProgramContext);

  return (
    <select {...props} value={typeName(props.getset.value)} onChange={e => props.getset.set(progCtx.types[e.currentTarget.value])}>
      {Object.values(progCtx.types.value).map(t => (
        <option value={typeName(t)}>{typeName(t)}</option>
      ))}
    </select>
  )
}

function ParamEditor(props: { paramIndex: number, func: GetSet<Function> }) {
  const param = props.func.value.params[props.paramIndex];

  const setParam: React.Dispatch<React.SetStateAction<Variable>> = React.useCallback((val) => {
    props.func.set((prev) => ({
      ...prev,
      params: prev.params.map((p, i) =>
        i === props.paramIndex
        ? (typeof val === "function"
          ? val(p)
          : val)
        : p
      ),
    }));
  }, [props.func.set, props.paramIndex]);

  const getsetParamType = React.useMemo<GetSet<Type>>(() => {
    return {
      value: param.type,
      set: (action) => setParam(prev => {
        return {
          ...prev,
          type: typeof action === "function" ? action(prev.type) : action
        };
      }),
    };
  }, [param, setParam]);

  return (
    <span>
      <input className={sharedStyles.transparentInput} value={param.name} onChange={e => setParam(prev => ({ ...prev, name: e.currentTarget.value }))}/>
      <TypeSelect getset={getsetParamType} style={{ display: "inline"}} />
    </span>
  );
}

interface DeclEditorHandle {
  focus: () => void ;
}

const DeclEditor = React.forwardRef<DeclEditorHandle, { decl: Variable | Function }>((props, ref) => {
  const { decl } = props;

  const progCtx = React.useContext(ProgramContext);

  const type: DeclType = "params" in props.decl ? "functions" : "variables";
  const getset = progCtx[type] as GetSet<Record<string, Variable | Function>>;

  const prevName = React.useRef(decl.name);

  const setDecl: React.Dispatch<React.SetStateAction<Variable | Function>> = React.useCallback(
    (v) => {
      getset.set(prev => {
        const newVal = typeof v === "function" ? v(prev[decl.name]) : v;
        const result = { ...prev };
        delete result[prevName.current];
        result[newVal.name] = newVal;
        prevName.current = newVal.name;
        return result;
      });
    },
    [getset, decl.name],
  );

  const nameInputRef = React.useRef<HTMLInputElement>(null);

  const firstRender = React.useRef(true);

  React.useEffect(() => {
    if (firstRender.current) {
      nameInputRef.current?.select();
      firstRender.current = false;
    }
  }, []);

  React.useImperativeHandle(ref, () => {
    return {
      focus: () => {
        nameInputRef.current?.focus();
      },
    };
  }, [nameInputRef]);

  const nameInput = React.useMemo(() =>
    <input
      ref={nameInputRef}
      className={sharedStyles.transparentInput}
      onKeyDown={e => {
        if (e.key === "Enter") {
          e.currentTarget.blur();
          return false;
        }
      }}
      onBlur={e => {
        const val = e.currentTarget.value;
        if (val.length > 0)
          setDecl(prev => ({ ...prev, name: val }));
        else
          e.currentTarget.focus();
      }}
    />
  , [setDecl]);

  React.useLayoutEffect(() => {
    if (nameInputRef.current !== null)
      nameInputRef.current.value = decl.name;
  }, []);

  const funcView = React.useMemo(() => {
    if (!("params" in decl))
      return undefined;

    return (
      <>
        {nameInput}
        <ul style={{ listStyle: "none", display: "inline", margin: 0 }}>
          {decl.params.map((_d, i) => (
            <li key={/*i*/i} style={{display: "inline"}}>
              <ParamEditor paramIndex={i} func={{
                value: decl,
                set: setDecl as React.Dispatch<React.SetStateAction<Function>>,
              }} />
            </li>
          ))}
        </ul>
      </>
    );
  }, [decl, setDecl, nameInput]);

  const varView = <>
    {nameInput}
  </>;

  return (
    <div>
      {"params" in decl ? (
        funcView
      ) : (
        varView
      )}
    </div>
  );
});

function ProgramContextEditor() {
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

  const lastVar = React.createRef<DeclEditorHandle>();
  const lastFunc = React.createRef<DeclEditorHandle>();

  const functionList = Object.values(functions);
  const variableList = Object.values(variables);

  return (
    <ProgramContext.Provider value={programContext}>
      <div>
        <section>
          <strong>Functions</strong>
          <ul style={{ listStyle: "none", margin: 0}}>
            {functionList.map((v, i) => (
              <li key={i}>
                <DeclEditor decl={v} ref={i === functionList.length - 1 ? lastFunc : undefined} />
              </li>
            ))}
          </ul>
          <button
            onClick={() => {
              setFunctions(prev => ({
                ...prev,
                new: prev.new || {
                  name: "new",
                  params: [],
                  return: undefined,
                  comment: undefined,
                },
              }));
            }}
          >+</button>
        </section>

        <section>
          <strong>Variables</strong>
          <ul style={{ listStyle: "none" }}>
            {variableList.map((v, i) => (
              <li key={i}>
                <DeclEditor decl={v} ref={i === variableList.length - 1 ? lastVar : undefined} />
              </li>
            ))}
          </ul>
          <button
            onClick={() => setVariables(prev => ({
              ...prev,
              new: prev.new || {
                name: "new",
                type: "i32",
                value: 0,
                comment: undefined
              },
            }))}
          >+</button>
        </section>

      </div>
    </ProgramContext.Provider>
  );
}

export function Ide(_props: Ide.Props) {
  return <div className={styles.ide}>
    <TextEditor onSyncSource={onSyncSource} />
    <div className={styles.visualEditor}>
      <span className={styles.graphEditor}>
        <TestGraphEditor onSyncGraph={onSyncGraph} />
      </span>
      <span className={styles.contextEditor}>
        <ProgramContextEditor />
      </span>
    </div>
  </div>;
}

namespace Ide {
  export interface Props {}
}

export default Ide;
