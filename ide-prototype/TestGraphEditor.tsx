import React, { useRef } from 'react'
import ReactFlow, {
  addEdge,
  Handle,
  NodeProps,
  Node,
  Controls,
  MiniMap,
  EdgeProps,
  getMarkerEnd,
  getBezierPath,
  Edge,
  useReactFlow,
  MarkerType,
  BaseEdge,
} from 'reactflow'
import 'reactflow/dist/style.css'
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

const initial: Node<{} | DialogueEntryNodeData>[] = [
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
  const [isConnected, setIsConnected] = React.useState(false);
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
    onConnect={(connectInfo) => setIsConnected(!!connectInfo)}
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

const CustomEdge = (props: EdgeProps) => {
  //const edgePath = getSmoothStepPath(props)
  const [edgePath] = getBezierPath(props)
  const markerEnd = getMarkerEnd(MarkerType.Arrow, props.markerEnd)
  return <BaseEdge path={edgePath} markerEnd={markerEnd} {...props} />
}

const edgeTypes = {
  default: CustomEdge,
} as const

const TestGraphEditor = (props: TestGraphEditor.Props) => {
  const [nodes, setNodes] = React.useState<Node[]>(initial)
  const [edges, setEdges] = React.useState<Edge[]>([])

  const addNode = React.useCallback(
    (nodeType: string, position: {x: number, y:number}) => {
      const newId = `${Math.round(Math.random() * Number.MAX_SAFE_INTEGER)}`
      setNodes(prev =>
        prev.concat({
          id: newId,
          type: nodeType,
          data: {
            title: 'test title',
            text: 'test text',
            onChange: (newVal: Partial<DialogueEntryNodeData>) =>
              setNodes(prev => {
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
            /*
            onDelete: () =>
              setElements(prev =>
                removeElements(
                  prev.filter(e => e.id === newId),
                  prev
                )
              ),
            */
          },
          position: position,
        })
      )
    },
    [setNodes, setEdges]
  )

  const [portraits, setPortraits] = React.useState(new Map<string, string>())

  const graph = useReactFlow();

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
              content: JSON.stringify({ nodes, edges }),
            })
          }}
        >
          Save
        </button>
        <button
          onClick={async () => {
            props.onSyncGraph({ nodes, edges });
          }}
        >
          Sync
        </button>
        <button
          onClick={async () => {
            const file = await uploadFile({ type: 'text' })
            const json = JSON.parse(file.content)
            setNodes(json.nodes)
            setEdges(json.edges)
          }}
        >
          Load
        </button>
      </div>
      {/* TODO: must memoize the context value */}
      <AppCtx.Provider value={{ portraits }}>
        <div className={styles.graph}>
          <ReactFlow
            nodes={nodes}
            edges={edges}
            onConnect={connection => setEdges(e => addEdge(connection, e))}
            defaultNodes={initial}
            defaultEdges={[]}
            deleteKeyCode={"DELETE"} /*DELETE key*/
            snapToGrid
            snapGrid={[15, 15]}
            nodeTypes={nodeTypes}
            //edgeTypes={edgeTypes}
            onEdgeClick={(_evt, edge) => {
              graph.deleteElements({edges: [edge]})
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
