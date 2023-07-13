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
  useEdges,
  useNodes,
} from 'reactflow'
import 'reactflow/dist/style.css'
import styles from './TestGraphEditor.module.css'
import { downloadFile, uploadFile } from './localFileManip'
import classNames from './classnames'
import { useValidatedInput, useStable } from "@bentley/react-hooks"
import { InputStatus } from '@bentley/react-hooks/lib/useValidatedInput'
import { Center } from "./Center";
import { persistentData } from "./AppPersistentState";
//import { NoderContext } from "./NoderContext";
import "./NoderContext";

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

interface AppState {
  graph: {
  }
}

const AppCtx = React.createContext<AppState>(
  new Proxy({} as AppState, {
    get() {
      throw Error('cannot consume null context')
    },
  })
)

type PinType = "string" | "num" | "exec"

interface NodeDesc {
  label: string,
  inputs:
    | { variadic: true, type: PinType }
    | { name: string, type: PinType, default?: any }[]
  outputs: { name: string, type: PinType }[]
}

const pinTypeColorMap: Record<PinType, string> = {
  num: "#ff0000",
  string: "#0000ff",
  exec: "#000000",
};

const pinTypeInputValidatorMap: Record<PinType, Parameters<typeof useValidatedInput<any>>[1]> = {
  num: undefined,
  string: {},
  exec: {},
};

function useForceUpdate() {
  const [, setFakeState] = React.useState(1);
  return useStable(() => () => setFakeState(prev => ++prev));
}

const NodeHandle = (props: {
  direction: "input" | "output";
  type: PinType;
  name: string;
  owningNodeId: string;
  index: number;
  siblingCount: number;
  setInputStatus?: (status: InputStatus, reason: string) => void;
}) => {
  const isInput = props.direction === "input"
  const id = `${props.owningNodeId}_${isInput}_${props.index}`;
  const edges = useEdges();
  const isConnected = React.useMemo(() =>
    edges.find(e => e.sourceHandle === id || e.targetHandle === id),
    [edges]
  );
  // TODO: highlight bad values and explain
  const [literalValue, literalValueInput, setLiteralValueInput, errorStatus, errorReason] = useValidatedInput();

  return <Handle
    id={id}
    type={isInput ? "source" : "target"}
    position={isInput ? "left" : "right"}
    className={classNames(styles.handle, isInput ? styles.inputHandle : styles.outputHandle)}
    style={{
      backgroundColor: pinTypeColorMap[props.type],
      top: `${100 * (props.index + 0.5) / props.siblingCount}%`,
    }}
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
          owningNodeId={props.id}
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
          owningNodeId={props.id}
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
  const graph = useReactFlow();
  const edges = useEdges<{}>();
  const nodes = useNodes<{}>();

  React.useEffect(() => {
    persistentData.initialNodes = nodes;
    persistentData.initialEdges = edges;
  }, [nodes, edges]);

  const addNode = React.useCallback(
    (nodeType: string, position: {x: number, y:number}) => {
      const newId = `${Math.round(Math.random() * Number.MAX_SAFE_INTEGER)}`
      graph.addNodes({
          id: newId,
          type: nodeType,
          data: {
            title: 'test title',
            text: 'test text',
            onChange: (newVal: Partial<DialogueEntryNodeData>) =>
              graph.setNodes(prev => {
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
            onDelete: () => graph.deleteElements({ nodes: [{ id: newId }] }),
          },
          position: position,
        }
      )
    },
    []
  )

  const connectingNodeId = React.useRef<string>();
  const graphContainerElem = React.useRef<HTMLDivElement>(null);

  return (
    <div className={styles.page}>
      <ContextMenu>
        {Object.keys(nodeTypes).map((nodeType) =>
          <button style={{ display: "block" }} key={nodeType} onClick={(e) => {
            const { top, left } = graphContainerElem.current!.getBoundingClientRect();
            addNode(nodeType, graph.project({
              x: e.clientX - left - 150/2,
              y: e.clientY - top,
            }))}
          }>{nodeType}</button>)
        }
      </ContextMenu>
      <div className={styles.rightClickMenu} />
      <div className={styles.toolbar}>
        <button
          onClick={() => {
            downloadFile({
              fileName: 'out.dialogue.json',
              content: JSON.stringify({ nodes: graph.getNodes(), edges: graph.getEdges() }),
            })
          }}
        >
          Save
        </button>
        <button
          onClick={async () => {
            //props.onSyncGraph({ nodes, edges });
          }}
        >
          Sync
        </button>
        <button
          onClick={async () => {
            const file = await uploadFile({ type: 'text' })
            const json = JSON.parse(file.content)
            graph.setNodes(json.nodes);
            graph.setEdges(json.edges);
          }}
        >
          Load
        </button>
      </div>
      {/* TODO: must memoize the context value */}
      <AppCtx.Provider value={{graph: {}}}>
        <div className={styles.graph} ref={graphContainerElem}>
          <ReactFlow
            defaultNodes={persistentData.initialNodes}
            defaultEdges={persistentData.initialEdges}
            deleteKeyCode={"Delete"} /*DELETE key*/
            snapToGrid
            snapGrid={[15, 15]}
            nodeTypes={nodeTypes}
            //edgeTypes={edgeTypes}
            onEdgeClick={(_evt, edge) => {
              graph.deleteElements({edges: [edge]})
            }}
            onConnectStart={(_, { nodeId }) => connectingNodeId.current = nodeId ?? undefined}
            // TODO: context menu on edge drop
            onConnectEnd={() => connectingNodeId.current = undefined}
            onEdgesDelete={(edges) => {
              for (const edge of edges) {
                graph.setNodes(nodes => nodes.map(n => {
                  if (n === edge.sourceNode)
                    n.data = {...n.data}; // force update
                  return n;
                }));
                const source = edge.sourceNode
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
