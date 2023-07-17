import React, { useContext, useEffect, useRef, useState } from "react";
import TestGraphEditor from "./TestGraphEditor";
import * as monaco from "monaco-editor/esm/vs/editor/editor.api"
import styles from "./Ide.module.css"
import { persistentData } from "./AppPersistentState";
import { NoderContext } from "./NoderContext";

const apiBaseUrl = "http://localhost:3001"

async function onSyncGraph(graph: any) {
  const resp = await fetch(`${apiBaseUrl}/graph_to_source`);
  const t = await resp.text()
}

async function onSyncSource(source: any) {
  const resp = await fetch(`${apiBaseUrl}/source_to_graph`);
  const t = await resp.text()
}

export function TextEditor(props: TextEditor.Props) {
  const [editor, setEditor] = useState<monaco.editor.IStandaloneCodeEditor | null>(null);
  const monacoElem = useRef<HTMLDivElement>(null);

  const [editorProgram, setEditorProgram] = useState(persistentData.editorProgram);

  const noder = useContext(NoderContext);

  useEffect(() => {
    const marshalledSrc = noder.wasmUtils.marshalString(editorProgram);
    const resultPtr = noder.noder.exports.readSrc(marshalledSrc._ptr);
    // FIXME: ptrToStr creates a botched string
    const result = noder.wasmUtils.ptrToStr(resultPtr);
    marshalledSrc.free();
    //console.log(result);
  }, [editorProgram]);

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

export function Ide(_props: Ide.Props) {
  return <div className={styles.split}>
    <TextEditor onSyncSource={onSyncSource} />
    <span className={styles.graphEditor}>
      <TestGraphEditor onSyncGraph={onSyncGraph} />
    </span>
  </div>;
}

namespace Ide {
  export interface Props {}
}

export default Ide;
