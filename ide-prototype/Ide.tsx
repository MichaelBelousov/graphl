import React from "react";
import DialogueEditor from "./DialogueEditor";

export function Ide(_props: Ide.Props) {
  return <div className="ide_columns">
    <textarea id="editor" />
    <DialogueEditor />
  </div>;
}

namespace Ide {
  export interface Props {}
}

export default Ide;
