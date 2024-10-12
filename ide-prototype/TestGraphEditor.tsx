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
  Background,
  ReactFlowInstance,
  Panel,
} from 'reactflow'
import 'reactflow/dist/style.css'
import styles from './TestGraphEditor.module.css'
import { downloadFile, uploadFile } from './localFileManip'
import classNames from './classnames'
import { useValidatedInput, useStable, useOnMount } from "@bentley/react-hooks"
import { InputStatus } from '@bentley/react-hooks/lib/useValidatedInput'
import { Center } from "./Center";
import { persistentData } from "./AppPersistentState";
import { NoderContext, Type, Value, Variable, Function } from './NoderContext'

function sortedKeys<T>(t: T): T {
  return Object.fromEntries(Object.entries(t).sort(([ka], [kb]) => ka.localeCompare(kb)));
}

// FIXME: remove
interface AppState {
  graph: {}
}

const AppCtx = React.createContext<AppState>(
  new Proxy({} as AppState, {
    get() {
      throw Error('cannot consume null context')
    },
  })
)

type PinType = "string" | "num" | "exec" | "bool" | string;

interface Input {
  label: string
  type: PinType
  default?: any
}

interface Output {
  label: string
  type: PinType
}

interface NodeDesc {
  label: string,
  inputs:
    | { variadic: true, type: PinType }
    | Input[]
  outputs:
    | { variadic: true, type: PinType }
    | Output[]
}

interface NodeData {
  literalInputs: Record<number, any>;
  variadicInputs?: Input[];
  variadicOutputs?: Output[];
  fullDesc: NodeDesc;
  setTarget?: string;
  comment?: string;
  isEntry: boolean;
}

interface NodeState extends NodeData {
  /** shallow merges in a patch to the data for that entry */
  onChange(newData: Partial<NodeData>): void
}

function colorForPinType(pinType: PinType) {
  const specificPinColors = {
    "": "#000000",
    "exec": "#ffffff",
    "num": "#ff0000",
    "string": "#00ff00",
    "bool": "#0000ff",
    "vector": "#ffff00",
  };
  const maybeSpecificPinColor = specificPinColors[pinType]
  if (maybeSpecificPinColor !== undefined)
    return maybeSpecificPinColor;

  pinType = pinType.repeat(6); // FIXME: this causes grayscale values for like "T"
  const charCodes = [
    48 + pinType.charCodeAt(0) % 16,
    48 + pinType.charCodeAt(1) % 16,
    48 + pinType.charCodeAt(2) % 16,
    48 + pinType.charCodeAt(3) % 16,
    48 + pinType.charCodeAt(4) % 16,
    48 + pinType.charCodeAt(5) % 16,
  ];
  for (let i = 0; i < charCodes.length; ++i) {
    if (charCodes[i] > 57)
      charCodes[i] = 65 + charCodes[i] - 58; // shift from 0-9 utf-8 to A-F
  }
  return "#" + String.fromCharCode(...charCodes);
}

const pinTypeInputValidatorMap: Record<PinType, Parameters<typeof useValidatedInput<any>>[1]> = {
  num: undefined,
  string: {},
  exec: {},
};

const useForceUpdateNode = () => {
  const graph = useReactFlow();
  return (nodeId: string) => {
    graph.setNodes(nodes => nodes.map(n => {
      if (n.id === nodeId)
        n.data = {...n.data}; // force update
      return n;
    }));
  };
}

const LiteralInput = (props: {
  type: PinType,
  literalInputs: NodeData["literalInputs"]
  default?: any,
  index: number,
  owningNodeId: string,
}) => {
  if (!(props.index in props.literalInputs))
    props.literalInputs[props.index] = props.default;

  const noder = React.useContext(NoderContext);
  const typeDescriptor = noder.lastTypeDefs[props.type];
  const isEnum = typeof typeDescriptor === "object" && typeDescriptor && "enum" in typeDescriptor;

  // TODO: highlight bad values and explain
  const [literalValue, literalValueInput, setLiteralValueInput, _errorStatus, _errorReason]
    = useValidatedInput<boolean | string | number | { symbol: string }>(props.literalInputs[props.index], {
    ...props.type === "bool" ? {
      parse: (x) => ({ value: !!x }),
      validate: () => ({ valid: true }),
      pattern: /.*/ // BUG: some idiot didn't make pattern/validate mutually exclusive
    } : props.type === "num" ? {
      // BUG: copy and pasted from useValidatedInput because some idiot forgot to make export the defaults
      parse: (text) => {
        const result = parseFloat(text);
        if (Number.isNaN(result)) return { value: null, status: "invalid number" };
        else return { value: result };
      },
      pattern: /^-?\d*(\.\d+)?$/i,
    } : props.type === "string" ? {
      parse: (x) => ({ value: x }),
      validate: () => ({ valid: true }),
      pattern: /.*/
    } : isEnum ? {
      parse: (x) => ({ value: { symbol: x } }),
      validate: () => ({ valid: true }),
      pattern: /.*/
    } : {
      parse: () => ({ value: { symbol: "#void" } }),
      validate: () => ({ valid: true }),
      pattern: /.*/
    },
  });

  const graph = useReactFlow();

  React.useEffect(() => {
    graph.setNodes(prev => prev.map((n: Node<NodeData>) => {
      if (n.id === props.owningNodeId) {
        n.data = { ...n.data };
        n.data.literalInputs[props.index] = literalValue;
      }
      return n;
    }));
  // HACK: literal value may not be referentially stable, so effect dependency is its input, which
  // thank goodness uses useMemo so should be correct
  }, [literalValueInput, props.owningNodeId]);

  const forceUpdateNode = useForceUpdateNode();

  if (props.type === "num")
    return <input
      value={literalValueInput}
      onChange={(e) => setLiteralValueInput(e.currentTarget.value)}
      style={{width: "8em"}}
    />;

  if (props.type === "string")
    return <input
      value={literalValueInput}
      onChange={(e) => setLiteralValueInput(e.currentTarget.value)}
      style={{width: "8em"}}
    />;


  if (props.type === "bool") {
    return <input
      type="checkbox"
      checked={!!literalValueInput}
      onChange={() => {
        setLiteralValueInput(prev => prev === "" ? "true" : "")
        // FIXME: not working
        forceUpdateNode(props.owningNodeId);
      }}
    />;
  }

  if (isEnum) {
    return (
      <select
        defaultValue={props.literalInputs[props.index]}
        value={literalValueInput}
        onChange={e => setLiteralValueInput(e.currentTarget.value)}
      >
        <option value=""/>
        {typeDescriptor.enum.map((v, i) => {
          const [key, label] = typeof v === "object" && v !== null && "symbol" in v
            ? [v.symbol, `'${v.symbol}`]
            : [`${v}`, `${v}`];
          return (
            <option
              defaultValue={props.literalInputs[props.index]}
              value={key}
              key={key}
            >
              {label}
            </option>
          );
        })}
      </select>
    );
  }

  return null;
};

const NodeHandle = (props: {
  direction: "input" | "output";
  type: PinType;
  label: string;
  owningNodeId: string;
  index: number;
  default?: any;
  setInputStatus?: (status: InputStatus, reason: string) => void;
} & NodeData) => {
  const isInput = props.direction === "input"
  const id = `${props.owningNodeId}_${isInput}_${props.index}`;
  const edges = useEdges();
  const isConnected = React.useMemo(() =>
    edges.find(e => e.sourceHandle === id || e.targetHandle === id),
    [edges]
  );

  if (!(props.index in props.literalInputs))
    props.literalInputs[props.index] = props.default;

  const label = <label>{props.label}</label>;

  return (
    <div 
      className={classNames(styles.handle, isInput ? styles.inputHandle : styles.outputHandle)}
    >
      {!isInput && label}
      <Handle
        id={id}
        type={isInput ? "source" : "target"}
        position={isInput ? "left" : "right"}
        className={classNames(
          styles.knob,
          props.type === "exec"
            ? styles.arrowRight
            : isInput
              ? styles.inputHandle
              : styles.outputHandle,
        )}
        style={{
          backgroundColor: colorForPinType(props.type),
        }}
      />
      {isInput && label}
      {isInput && !isConnected && <LiteralInput {...props} />}
    </div>
  );
};

function assert(condition: any, message?: string): asserts condition {
  if (!condition)
    throw Error(message ?? "Assertion error, condition was falsey");
}

const makeNodeComponent = (nodeId: string, nodeDesc: NodeDesc) => (props: NodeProps<NodeState>) => {
  const graph = useReactFlow();
  const edges = useEdges();

  const [inputs, setInputs] = "variadic" in nodeDesc.inputs
    ? React.useState<Input[]>(props.data.variadicInputs ?? [])
    : [nodeDesc.inputs];

  const [outputs, setOutputs] = "variadic" in nodeDesc.outputs
    ? React.useState<Output[]>(props.data.variadicOutputs ?? [])
    : [nodeDesc.outputs];

  const variadicType = "variadic" in nodeDesc.inputs && nodeDesc.inputs.type
                    || "variadic" in nodeDesc.outputs && nodeDesc.outputs.type;

  const firstHandleId = `${props.id}_true_0`;

  // TODO: chain inferrence...
  const inferredType = React.useMemo(() => {
    if (inputs?.[0]?.type !== "T")
      return undefined;
    // FIXME: why are these directions backwards?
    const firstSourceEdge = edges.find(e => firstHandleId === e.sourceHandle);
    if (firstSourceEdge === undefined)
      return undefined;
    const targetOutputIndex = parseInt(firstSourceEdge.targetHandle!.split("_")[2]);
    const targetNode = graph.getNode(firstSourceEdge.target);
    if (!targetNode)
      return undefined;
    const targetOutput = targetNode.data.fullDesc.outputs[targetOutputIndex] as Output;
    return targetOutput.type;
  }, [edges, graph]);

  const noder = React.useContext(NoderContext);
  const commentElem = React.useRef<HTMLElement>(null);

  return (
    <div
      className={styles.node}
      style={{
        width: "max-content",
      }}
    >
      <div className={styles.nodeHeader}>
        <strong>{nodeDesc.label}</strong>
        <em className={classNames(styles.nodeComment, !props.data.comment && styles.nodeCommentEmpty)}
            ref={commentElem}
            contentEditable
            defaultValue={props.data.comment}
            // TODO: use onFocus/onBlur
            onInput={e => {
              const value = e.currentTarget.textContent
              if (value) {
                props.data.comment = value;
                commentElem.current?.classList.remove(styles.nodeCommentEmpty);
              } else {
                props.data.comment = "";
                commentElem.current?.classList.add(styles.nodeCommentEmpty);
              }
        }}>
          {props.data.comment /* this warns but defaultValue doesn't work */}
        </em>
        {variadicType &&
          <button
            onClick={() => (setOutputs ?? setInputs)?.(prev => {
              const result = prev.concat({label: `${prev.length}`, type: variadicType });
              if (setOutputs) props.data.variadicOutputs = result;
              else props.data.variadicInputs = result;
              return result;
            })}
            className={classNames(styles.deleteButton, styles.clickable)}
          >
            <Center>
              +
            </Center>
          </button>
        }
        {nodeId === "set!" && <>
          <select defaultValue={props.data.setTarget} onChange={e => { props.data.setTarget = e.currentTarget.value }}>
            {/* noder.lastVarDefs */}
            {Object.entries({
              ...noder.lastFunctionDefs,
              DroneState: {},
              OverTime: {},
            }).map(([name, _func]) =>
              <option value={name} key={name}>{name}</option>
            )}
          </select>
        </>}
        <button
          onClick={() => graph.deleteElements({ nodes: [{ id: props.id }] })}
          className={classNames(styles.deleteButton, styles.clickable)}
        >
          <Center>
            &times;
          </Center>
        </button>
      </div>
      <div className={styles.connectionsGrid}>
        <div className={styles.inputsColumn}>
          {inputs.map((input, i) =>
            <NodeHandle
              {...input}
              {...props.data}
              type={inferredType ?? input.type}
              key={i}
              owningNodeId={props.id}
              direction="input"
              index={i}
            />
          )}
        </div>
        <div className={styles.outputsColumn}>
          {outputs.map((output, i) =>
            <NodeHandle
              {...output}
              {...props.data}
              type={inferredType ?? output.type}
              key={i}
              owningNodeId={props.id}
              direction="output"
              index={i}
            />
          )}
        </div>
      </div>
    </div>
  )
};

const UnknownNode = (props: NodeProps<NodeState>) => {
  // TODO: store connections on data in case the correct type is restored
  return (
    <div className={styles.node} style={{ height: 50, width: 100 }}>
      <div className={styles.nodeHeader}>
        <button className={styles.deleteButton}>
          &times;
        </button>
      </div>
      <Center>
        <strong>Unknown type '{props.data.fullDesc.label}'</strong>
      </Center>
    </div>
  )
};

import { nodes as builtinNodeTypes } from "../libs/std/builtin.json"
import { ContextMenu } from './ContextMenu'

const CustomEdge = (props: EdgeProps) => {
  // TODO: draw path from boundary of handle box
  const [edgePath] = getBezierPath({ ...props })
  const markerEnd = getMarkerEnd(MarkerType.Arrow, props.markerEnd)
  return <BaseEdge path={edgePath} markerEnd={markerEnd} {...props} />
}

const edgeTypes = {
  default: CustomEdge,
} as const

const save = (edges: Edge[], fileName: string) => {
  interface SerializedNode extends Node {
    inputs: string[];
    outputs: string[];
  }
  const nodes = new Map<string, SerializedNode>();

  function fromFlowNode(node: Node): SerializedNode {
    const nodeData = node.data as NodeData;
    // TODO: unscrew types
    if (!("isEntry" in nodeData))
      (nodeData as NodeData).isEntry = node.type === "CustomTickEntry";

    const result = {
      ...node,
      inputs: new Array(nodeData.fullDesc.inputs.length ?? 0),
      outputs: new Array(nodeData.fullDesc.outputs.length ?? 0),
    };

    for (const [key, value] of Object.entries(nodeData.literalInputs)) {
      const index = +key;
      result.inputs[key] = value;
    }

    return result;
  }

  for (let i = 0; i < edges.length; ++i) {
    const edge = edges[i];
    assert(edge.sourceHandle && edge.targetHandle);
    // flow's graph directionality is arbitrary to us
    // establish direction based on whether handle is input or output
    const [handle1NodeId, handle1IsInput, handle1Index] = edge.sourceHandle.split("_");
    const [handle2NodeId, handle2IsInput, handle2Index] = edge.targetHandle.split("_");
    assert(handle1NodeId && handle1IsInput && handle1Index);
    assert(handle2NodeId && handle2IsInput && handle2Index);
    const handle1 = { nodeId: handle1NodeId, handleIndex: +handle1Index, handleId: edge.sourceHandle };
    const handle2 = { nodeId: handle2NodeId, handleIndex: +handle2Index, handleId: edge.targetHandle };
    const toZigHandle = ({ nodeId, handleIndex }: typeof handle1) => ({ nodeId, handleIndex });
    const { source, target } = handle1IsInput
      ? { source: handle2, target: handle1 }
      : { source: handle1, target: handle2 };
    const sourceNode = graph.getNode(source.nodeId);
    const targetNode = graph.getNode(target.nodeId);
    assert(sourceNode && targetNode);

    let sourceResultNode = nodes.get(source.nodeId);
    if (sourceResultNode === undefined) {
      sourceResultNode = fromFlowNode(sourceNode);
      nodes.set(source.nodeId, sourceResultNode);
    }
    sourceResultNode.outputs[source.handleIndex] = toZigHandle(target);

    let targetResultNode = nodes.get(target.nodeId);
    if (targetResultNode === undefined) {
      targetResultNode = fromFlowNode(targetNode);
      nodes.set(target.nodeId, targetResultNode);
    }
    targetResultNode.inputs[target.handleIndex] = toZigHandle(source);
  }

  downloadFile({
    fileName,
    content: JSON.stringify({
      nodes: Object.fromEntries(nodes.entries()),
      edges,
    }, null, "  "),
  })
};


const ToolsPanel = (props: {
  graph: ReactFlowInstance<{}, {}>,
  onSyncGraph: TestGraphEditor.Props["onSyncGraph"],
  fileName: string,
  setFileName: (v: string) => void,
}) => {
  return (
    <div style={{ display: "flex", flexDirection: "row", alignItems: "center" }}>
      <>
        <button
          title={"Save"}
          onClick={() => save(props.graph.getEdges(), props.fileName)}
        >
          Save
        </button>
      </>

      <>
        <button
          onClick={async () => {
            props.onSyncGraph({
              nodes: props.graph.getNodes().reduce((prev, curr) => {
                const node = { ...curr };
                node.outputs = curr.data.fullDesc.outputs;
                node.inputs = curr.data.fullDesc.inputs;
                prev[node.id] = node;
                return prev;
              }, {} as Record<string, Node<{}>>),
              edges: props.graph.getEdges(),
            });
          }}
        >
          Sync
        </button>
      </>

      <button
        onClick={async () => {
          const file = await uploadFile({ type: 'text' })
          const json = JSON.parse(file.content)
          props.graph.setNodes(Object.values(json.nodes));
          props.graph.setEdges(json.edges);
        }}
      >
        Load
      </button>

      <button
        onClick={async () => {
          props.graph.setNodes([]);
          props.graph.setEdges([]);
        }}
      >
        Reset
      </button>

      <input
        style={{ border: 0, backgroundColor: "transparent" }}
        value={props.fileName}
        onChange={(e) => props.setFileName(e.currentTarget.value)}
        placeholder="filename"
      />

    </div>
  );
};

const TestGraphEditor = (props: TestGraphEditor.Props) => {
  const graph = useReactFlow<{}, {}>();
  const edges = useEdges<{}>();
  const nodes = useNodes<{}>();

  React.useEffect(() => {
    persistentData.initialNodes = nodes;
    persistentData.initialEdges = edges;
  }, [nodes, edges]);

  const noder = React.useContext(NoderContext);

  const nodeDescs = React.useMemo(() => {
    const result = { ...noder.lastNodeTypes, ...builtinNodeTypes };
    // HACK: to avoid implementing the language (return is inferred), explicitly set outputs:
    if (result["get-actor-location"])
      result["get-actor-location"].outputs = [{label: "a", type: "vector"}];

    if (result["vector-length"])
      result["vector-length"].outputs = [{label: "a", type: "f64"}];

    if (result["single-line-trace-by-channel"]) {
      result["single-line-trace-by-channel"].inputs = [
        { "label": "", "type": "exec" },
        { "label": "start", "type": "vector" },
        { "label": "end", "type": "vector" },
        { "label": "channel", "type": "trace-channels" },
        { "label": "trace-complex", "type": "bool" },
        { "label": "actors-to-ignore", "type": "actor-list" },
        { "label": "draw-debug-type", "type": "draw-debug-types", "default": { "symbol": "none" } },
        { "label": "ignore-self", "type": "bool", "default": false }
      ];
      result["single-line-trace-by-channel"].outputs = [{label: "", type: "exec"}, {label:"Out Hit", type: "Hit"}, {label:"DidHit", type: "bool"}];
    }

    if (result["delay"]) {
      result["delay"].inputs = [{ label: "", type: "exec"}, { label: "seconds", type: "num" }];
      result["delay"].outputs = [{ label: "", type: "exec" }];
    }

    result["break-hit-result"] = {
      description: "break a hit result struct",
      label: "Break Hit Result",
      inputs: [
        { label: "hit", type: "Hit" },
      ],
      outputs: [
        { label: "location", type: "vector" },
        { label: "normal", type: "vector" },
        { label: "impact point", type: "vector" },
        { label: "impact normal", type: "vector" },
        { label: "physical material", type: "physical materials" },
        { label: "hit actor", type: "actor" },
        { label: "hit component", type: "scene-component" },
        { label: "hit bone name", type: "string" },
      ]
    };

    result["do-once"] = {
      label: "Do Once",
      description: "do something once",
      inputs: [
        { label: "", type: "exec" },
        { label: "Reset", type: "exec" },
        { label: "Start Closed", type: "bool", default: false },
      ],
      outputs: [
        { label: "Completed", type: "exec" },
      ]
    };

    result["CustomTickCall"] = {
      label: "CustomTick",
      description: "call custom tick",
      inputs: [
        { label: "", type: "exec" },
        { label: "target", type: "Pawn", default: "self" },
      ],
      outputs: [
        { label: "", type: "exec" },
      ]
    };

    result["CustomTickEntry"] = {
      label: "CustomTick",
      description: "close custom tick",
      inputs: [],
      outputs: [
        { label: "", type: "exec" },
      ]
    };


    if (result["get-socket-location"])
      result["get-socket-location"].outputs = [
        { label: "return", type: "vector" },
      ];

    result["Move Component To"] = {
      label: "Move Component To",
      description: "local function",
      data: {
        isAsync: true,
      },
      inputs: [
        { label: "Move", type: "exec" },
        { label: "Stop", type: "exec" },
        { label: "Return", type: "exec" },
        { label: "Component", type: "scene-component" },
        { label: "Target Relative Location", type: "vector" },
        { label: "Target Relative Rotation", type: "rotator" },
        { label: "Ease Out", type: "bool" },
        { label: "Ease In", type: "bool" },
        { label: "Over Time", type: "f32" },
      ],
      outputs: [
        { label: "Completed", type: "exec" },
      ],
    };

    return sortedKeys(result);
  }, [noder.lastNodeTypes]);

  const addNode = React.useCallback(
    (nodeType: string, position: {x: number, y:number}) => {
      const newId = `${Math.round(Math.random() * Number.MAX_SAFE_INTEGER)}`
      graph.addNodes({
          id: newId,
          type: nodeType,
          data: {
            onChange: (newVal: Partial<NodeState>) =>
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
            literalInputs: {},
            typeIfDefaulted: nodeType,
            fullDesc: nodeDescs[nodeType],
            isEntry: nodeType === "CustomTickEntry",
          },
          position: position,
        }
      )
    },
    [nodeDescs]
  )

  const connectingNodeId = React.useRef<string>();
  const graphContainerElem = React.useRef<HTMLDivElement>(null);

  // TODO: make the nodes dynamic so Reactflow doesn't re-render them
  const nodeTypes = React.useMemo(() => {
    return {
      ...Object.fromEntries(
        Object.entries(nodeDescs)
          .map(([k, v]) => [k, makeNodeComponent(k, v as NodeDesc)])
      ),
      default: UnknownNode,
    };
  }, [nodeDescs]);

  const [fileName, setFileName] = React.useState("graph.json");

  return (
    <div className={styles.page}>
      <ContextMenu>
        <div className={styles.addNodeMenu}>
          {Object.keys(nodeTypes)
            .filter(key => key !== "default")
            .map((nodeType) =>
              <em className={styles.addNodeMenuOption} key={nodeType} onClick={(e) => {
                const { top, left } = graphContainerElem.current!.getBoundingClientRect();
                addNode(nodeType, graph.project({
                  x: e.clientX - left - 150/2,
                  y: e.clientY - top,
                }))}
              }>
                {nodeType}
              </em>
            )
          }
        </div>
      </ContextMenu>
      <div className={styles.rightClickMenu} />
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
              }
            }}
          >
            <Controls />
            <MiniMap
              zoomable pannable
              color="var(--fg-1)"
              // FIXME: node color should be  a function that returns based on types...
              maskColor="#2d2d2dcc" // FIXME: reference var(--bg-1)
              style={{
                backgroundColor: "var(--bg-2)",
              }}
            />
            <Background />
            <Panel position="top-left">
              <ToolsPanel fileName={fileName} setFileName={setFileName} graph={graph} onSyncGraph={props.onSyncGraph} />
            </Panel>
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

