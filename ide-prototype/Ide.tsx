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

function DeclEditor(props: { decl: Variable | Function }) {
  const { decl } = props;

  const progCtx = React.useContext(ProgramContext);

  const type: DeclType = "params" in props.decl ? "functions" : "variables";
  const getset = progCtx[type] as GetSet<Record<string, Variable | Function>>;

  const setDecl: React.Dispatch<React.SetStateAction<Variable | Function>> = React.useCallback(
    (v) => {
      getset.set(prev => {
        const newVal = typeof v === "function" ? v(prev[decl.name]) : v;
        const result = { ...prev };
        delete result[decl.name];
        result[decl.name] = newVal;
        return result;
      });
    },
    [getset, decl.name],
  );

  const params = React.useMemo(() => {
    if (!("params" in decl))
      return undefined;

    return decl.params.map((_, i) => (
      <ul style={{ listStyle: "none", display: "inline", margin: 0 }}>
        <li key={i} style={{display: "inline"}}>
          <ParamEditor paramIndex={i} func={{
            value: decl,
            set: setDecl as React.Dispatch<React.SetStateAction<Function>>,
          }} />
        </li>
      </ul>
    ));
  }, [decl, setDecl]);

  return (
    <div>
      <strong>{decl.name}</strong>
      {"params" in decl ? (
        <>{params}</>
      ) : (
        <>
        </>
      )}
    </div>
  );
};

function ProgramContextEditor() {
  const [variables, setVariables] = React.useState({} as Record<string, Variable>);
  const [functions, setFunctions] = React.useState({} as Record<string, Function>);

  const programContext: ProgramContext = React.useMemo(() => ({
    variables: {
      value: variables,
      set: setVariables,
    },
    functions: {
      value: functions,
      set: setFunctions,
    },
  }), [variables, functions, setVariables, setFunctions]);

  return (
    <ProgramContext.Provider value={programContext}>
      <div>
        <section>
          <h3> Functions </h3>
          <ul style={{ listStyle: "none", margin: 0}}>
            {Object.values(functions).map((v, i) => (
              <li key={i}>
                <DeclEditor decl={v} />
              </li>
            ))}
          </ul>
          <button
            onClick={() => setFunctions(prev => ({ ...prev, "newFunc": {
              name: "",
              params: [],
              return: undefined,
              comment: undefined
            }}))}
          >+</button>
        </section>
        <section>
          <h3> Variables </h3>
          <ul style={{ listStyle: "none" }}>
            {Object.values(variables).map((v, i) => (
              <li key={i}>
                <DeclEditor decl={v} />
              </li>
            ))}
          </ul>
          <button
            onClick={() => setVariables(prev => ({ ...prev, "newVar": {
              name: "",
              type: "i32",
              initial: 0,
              comment: undefined,
            }}))}
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
