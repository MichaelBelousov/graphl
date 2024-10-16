import React, { useContext, useEffect, useRef, useState } from "react";
import TestGraphEditor from "./TestGraphEditor";
import * as monaco from "monaco-editor/esm/vs/editor/editor.api"
import styles from "./Ide.module.css"
import sharedStyles from "./shared.module.css";
import { persistentData } from "./AppPersistentState";
import { NoderContext, Variable, Function, Type, defaultTypes, native } from "./NoderContext";
import * as zigar from "zigar-runtime";
import { GrapplProvider } from "./GrapplContext";
//import debounce from "lodash.debounce";

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
    if (monacoElem.current)
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
        return result;
      })
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
    <div>
      <NameInput
        initialValue={param.name}
        onChange={val => setParam(prev => ({ ...prev, name: val, }))}
      />
      <TypeSelect getset={getsetParamType} style={{ display: "inline"}} />
    </div>
  );
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

const VarDeclEditor = ({ getset }: { getset: GetSet<Variable> }) => {
  return (
    <>
      <NameInput
        initialValue={getset.value.name}
        onChange={val => getset.set(prev => ({ ...prev, name: val }))}
      />
      <TypeSelect
        getset={{
          value: getset.value.type,
          set: (val) => {
            getset.set(prev => {
              const newVal = typeof val === "function" ? val(prev.type) : val;
              return {
                ...prev,
                type: newVal,
              };
            });
          }
        }}
        style={{ display: "inline"}}
      />
    </>
  );
};

const FuncDeclEditor = ({ getset }: { getset: GetSet<Function>  }) => {
  const params = React.useMemo(() => {
    return (
      <>
        <ul style={{ listStyle: "none", margin: 0, padding: 0 }}>
          {getset.value.params.map((_d, i) => (
            <li key={/*i*/i} style={{display: "inline"}}>
              <ParamEditor paramIndex={i} func={{
                value: getset.value,
                set: getset.set,
              }} />
            </li>
          ))}
        </ul>
      </>
    );
  }, [getset.value, getset.set]);

  return (
    <>
      <NameInput
        initialValue={getset.value.name}
        onChange={val => getset.set(prev => ({ ...prev, name: val }))}
      />
      <div style={{marginLeft: "15px"}}>
        <small><strong>Parameters</strong></small>
        {params}
        <button onClick={() => {
          getset.set(prev => ({
            ...prev,
            params: [
              ...getset.value.params,
              {
                name: "new",
                type: "i32",
                initial: 0,
                comment: undefined,
              }
            ],
          }));
        }}>+</button>
        <div>
          <span><small><strong>Result</strong></small></span>
          <TypeSelect getset={{
            value: getset.value.return,
            set: (val) => {
              getset.set(prev => {
                const newVal = typeof val === "function" ? val(prev.return) : val;
                return {
                  ...prev,
                  return: newVal,
                };
              });
            },
          }} />
        </div>
      </div>
    </>
  );
};

const DeclEditor = (props: { decl: Variable | Function }) => {
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

  if ("params" in decl)
    // NOTE: memoize this props?
    return <FuncDeclEditor getset={{ value: decl, set: setDecl as React.Dispatch<React.SetStateAction<Function>> }} />

  else
    return <VarDeclEditor getset={{ value: decl, set: setDecl as React.Dispatch<React.SetStateAction<Variable>> }} />
};

function ProgramContextEditor() {
  const progCtx = React.useContext(ProgramContext);
  const functionList = Object.values(progCtx.functions.value);
  const variableList = Object.values(progCtx.variables.value);

  return (
    <div>
      <section>
        <strong>Functions</strong>
        <ul style={{ listStyle: "none", margin: 0, padding: 0 }}>
          {functionList.map((v, i) => (
            <li key={i}>
              <DeclEditor decl={v} />
            </li>
          ))}
        </ul>
        <button
          onClick={() => {
            progCtx.functions.set(prev => ({
              ...prev,
              new: prev.new || {
                name: "new",
                params: [],
                return: "void",
                comment: undefined,
              },
            }));
          }}
        >+</button>
      </section>

      <section>
        <strong>Variables</strong>
        <ul style={{ listStyle: "none", margin: 0, padding: 0 }}>
          {variableList.map((v, i) => (
            <li key={i}>
              <DeclEditor decl={v} />
            </li>
          ))}
        </ul>
        <button
          onClick={() => progCtx.variables.set(prev => ({
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
  );
}

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
      <GrapplProvider>
        <div className={styles.ide}>
          <TextEditor onSyncSource={async () => {}} editor={getsetEditor} />
          <div className={styles.visualEditor}>
            <span className={styles.graphEditor}>
              <TestGraphEditor onSyncGraph={async (graph) => {
                // TODO: give it a real diagnostic type lol?
                const diagnostic = {};
                await native.graphToSource(JSON.stringify(graph), diagnostic);
                console.log(diagnostic);
              }} />
            </span>
            <span className={styles.contextEditor}>
              <ProgramContextEditor />
            </span>
          </div>
        </div>
      </GrapplProvider>
    </ProgramContext.Provider>
  );
}

namespace Ide {
  export interface Props {}
}

export default Ide;
