import React, { useEffect, useRef, useState } from "react";
import TestGraphEditor from "./TestGraphEditor";
import * as monaco from "monaco-editor/esm/vs/editor/editor.api"
import styles from "./Ide.module.css"

const editorProgramKey = "editorProgram"

export function TextEditor() {
  const [editor, setEditor] = useState<monaco.editor.IStandaloneCodeEditor | null>(null);
  const monacoElem = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (monacoElem.current)
      setEditor((editor) => {
        return editor ?? monaco.editor.create(monacoElem.current!, {
          value: localStorage.getItem(editorProgramKey) ?? "",
          language: "scheme",
          theme: "vs-dark",
        })
      })
  }, [monacoElem.current]);
  return <div className={styles.textEditor} ref={monacoElem} />
}

export function Ide(_props: Ide.Props) {
  return <div className={styles.split}>
    <TextEditor />
    <span className={styles.graphEditor}> <TestGraphEditor /> </span>
  </div>;
}

namespace Ide {
  export interface Props {}
}

export default Ide;
