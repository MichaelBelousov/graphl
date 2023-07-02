import React from "react";
import TestGraphEditor from "./TestGraphEditor";

export function Ide(_props: Ide.Props) {
  return <div className="ide_columns">
    <textarea id="editor" />
    <TestGraphEditor />
  </div>;
}

namespace Ide {
  export interface Props {}
}

export default Ide;
