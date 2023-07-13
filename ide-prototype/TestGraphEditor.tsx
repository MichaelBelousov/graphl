import React, { useRef } from 'react'
import ReactFlow, {
  addEdge,
  Elements,
  Handle,
  NodeProps,
  Node,
  removeElements,
  Controls,
  MiniMap,
  isEdge,
  EdgeProps,
  getBezierPath,
  getMarkerEnd,
  getSmoothStepPath,
} from 'react-flow-renderer'
import styles from './TestGraphEditor.module.css'
import { downloadFile, uploadFile } from './localFileManip'
import classNames from './classnames'
import { useValidatedInput } from "@bentley/react-hooks"
import { InputStatus } from '@bentley/react-hooks/lib/useValidatedInput'
import { Center } from "./Center";

interface DialogueEntry {
  portrait?: string
  title: string
  text: string
}

interface DialogueEntryNodeData extends DialogueEntry {
  /** shallow merges in a patch to the data for that entry */
  onChange(newData: Partial<DialogueEntry>): void
  onDelete(): void
}

const initial: Elements<{} | DialogueEntryNodeData> = [
  {
    id: '1',
    type: 'input',
    data: {
      label: 'entry',
    },
    position: { x: 540, y: 100 },
  },
]

interface AppState {
  /** map of portrait file name to its [data]url */
  portraits: Map<string, string>
}

const AppCtx = React.createContext<AppState>(
  new Proxy({} as AppState, {
    get() {
      throw Error('cannot consume null context')
    },
  })
)

type PinType = "string" | "number" | "exec"

interface NodeDesc {
  label: string,
  inputs:
    | { variadic: true, type: PinType }
    | { name: string, type: PinType, default?: any }[]
  outputs: { name: string, type: PinType }[]
}

const pinTypeColorMap: Record<PinType, string> = {
  number: "#ff0000",
  string: "#0000ff",
  exec: "#000000",
};

const pinTypeInputValidatorMap: Record<PinType, Parameters<typeof useValidatedInput<any>>> = {
  number: [],
  string: [],
  exec: [],
};

const NodeHandle = (props: {
  direction: "input" | "output";
  type: PinType;
  name: string;
  index: number;
  siblingCount: number;
  setInputStatus?: (status: InputStatus, reason: string) => void;
}) => {
  const isInput = props.direction === "input"
  // FIXME
  const isConnected = false;
  const [literalValue, literalValueInput, setLiteralValueInput, errorStatus, errorReason] = useValidatedInput();

  return <Handle
    type="target"
    position={isInput ? "left" : "right"}
    className={classNames(styles.handle, isInput ? styles.inputHandle : styles.outputHandle)}
    style={{
      backgroundColor: pinTypeColorMap[props.type],
      top: `${100 * (props.index + 0.5) / props.siblingCount}%`,
    }}
    isConnectable
  >
    <div>
      <label>{props.name}</label>
      {isInput && !isConnected
        && <input
          value={literalValueInput}
          onChange={(e) => setLiteralValueInput(e.currentTarget.value)}
          style={{width: "8em"}}
        />
      }
    </div>
  </Handle>
};

function assert(condition: any, message?: string): asserts condition {
  if (!condition)
    throw Error(message ?? "Assertion error, condition was falsey");
}

const makeNodeComponent = (nodeDesc: NodeDesc) => (props: NodeProps<DialogueEntryNodeData>) => {
  const inputs = "variadic" in nodeDesc.inputs
    ? assert("variadic not yet supported") as never
    : nodeDesc.inputs;

  return (
    <div
      className={styles.node}
      style={{
        height: 30 * inputs.length,
        width: 150,
      }}
    >
      {inputs.map((input, i) =>
        <NodeHandle
          {...input}
          key={i}
          direction="input"
          index={i}
          siblingCount={inputs.length}
        />
      )}
      <Center>
        <strong>{nodeDesc.label}</strong>
      </Center>
      <button onClick={props.data.onDelete} className={styles.deleteButton}>
        &times;
      </button>
      {nodeDesc.outputs.map((output, i) =>
        <NodeHandle
          {...output}
          key={i}
          direction="output"
          index={i}
          siblingCount={nodeDesc.outputs.length}
        />
      )}
    </div>
  )
};

import { nodes as _nodeTypes } from "../libs/std/builtin.json"
import { ContextMenu } from './ContextMenu'

const nodeTypes = {
  ...Object.fromEntries(
    Object.entries(_nodeTypes)
      .map(([k, v]) => [k, makeNodeComponent(v as NodeDesc)])
  )
};

const CustomDefaultEdge = (props: EdgeProps) => {
  const edgePath = getSmoothStepPath(props)
  const markerEnd = getMarkerEnd(props.arrowHeadType, props.markerEndId)
  return (
    <>
      <path
        id={props.id}
        style={{ ...props.style, strokeWidth: 3 }}
        className="react-flow__edge-path"
        d={edgePath}
        markerEnd={markerEnd}
      />
    </>
  )
}

const edgeTypes = {
  // TODO: could just make this the "default" node
  default: CustomDefaultEdge,
} as const

const TestGraphEditor = (props: TestGraphEditor.Props) => {
  const [elements, setElements] = React.useState(initial)

  const addNode = React.useCallback(
    (nodeType: string, position: {x: number, y:number}) => {
      const newId = `${Math.round(Math.random() * Number.MAX_SAFE_INTEGER)}`
      setElements(prev =>
        prev.concat({
          id: newId,
          type: nodeType,
          data: {
            title: 'test title',
            text: 'test text',
            onChange: (newVal: Partial<DialogueEntryNodeData>) =>
              setElements(prev => {
                const copy = prev.slice()
                const index = copy.findIndex(elem => elem.id === newId)
                const elem = copy[index]
                copy[index] = {
                  ...elem,
                  data: {
                    ...elem.data,
                    ...newVal,
                  },
                }
                return copy
              }),
            onDelete: () =>
              setElements(prev =>
                removeElements(
                  prev.filter(e => e.id === newId),
                  prev
                )
              ),
          },
          position: position,
        })
      )
    },
    [setElements]
  )

  const [portraits, setPortraits] = React.useState(new Map<string, string>())

  return (
    <div className={styles.page}>
      <ContextMenu>
        {Object.keys(nodeTypes).map((nodeType) =>
          <button key={nodeType} onClick={(e) => addNode(nodeType, { x: e.pageX, y: e.pageY })}>{nodeType}</button>)
        }
      </ContextMenu>
      <div className={styles.rightClickMenu} />
      <div className={styles.toolbar}>
        <button
          onClick={() => {
            downloadFile({
              fileName: 'out.dialogue.json',
              content: JSON.stringify(elements),
            })
          }}
        >
          Save
        </button>
        <button
          onClick={async () => {
            props.onSyncGraph(elements);
          }}
        >
          Sync
        </button>
        <button
          onClick={async () => {
            const file = await uploadFile({ type: 'text' })
            const json = JSON.parse(file.content)
            setElements(json)
          }}
        >
          Load
        </button>
      </div>
      {/* TODO: must memoize the context value */}
      <AppCtx.Provider value={{ portraits }}>
        <div className={styles.graph}>
          <ReactFlow
            elements={elements}
            onConnect={params => setElements(e => addEdge(params, e))}
            onElementsRemove={toRemove =>
              setElements(e => removeElements(toRemove, e))
            }
            deleteKeyCode={46} /*DELETE key*/
            snapToGrid
            snapGrid={[15, 15]}
            nodeTypes={nodeTypes}
            edgeTypes={edgeTypes}
            onElementClick={(_evt, elem) => {
              if (isEdge(elem)) {
                setElements(elems => removeElements([elem], elems))
              }
            }}
          >
            <Controls />
            <MiniMap />
          </ReactFlow>
        </div>
      </AppCtx.Provider>
    </div>
  )
}

namespace TestGraphEditor {
  export interface Props {
    onSyncGraph: (graph: any) => Promise<void>;
  }
}

export default TestGraphEditor
