import React from "react";
import TestGraphEditor from "./TestGraphEditor";
import styles from "./Ide.module.css"

export function Ide(_props: Ide.Props) {
  return <div className={styles.split}>
    <textarea id="editor" />
    <TestGraphEditor />
  </div>;
}

namespace Ide {
  export interface Props {}
}

export default Ide;
