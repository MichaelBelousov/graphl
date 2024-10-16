import native from "../lang-lib/src/main.zig";
import { Node as ReactFlowNode, Edge as ReactFlowEdge } from "reactflow";

export type ZigValue =
  | number
  | string
  | boolean
  | null
  | { symbol: string };


export interface Link {
  target: unknown;
  pin_index: bigint;
  sub_index: bigint;
}

export interface JsLink {
  targetId: NodeId;
  target?: JsNode;
  pin_index: number;
  sub_index?: number;
}


export type Input =
  | { link: Link; }
  | { value: ZigValue; };

export type JsInput =
  | { link: JsLink; }
  | { value: ZigValue; };


export interface Output {
  link: Link;
}

export interface JsOutput {
  link: JsLink;
}

export interface NodeDesc {
  name: string,
  getInputs(): Input[];
  getOutputs(): (Output | null)[];
}

export interface IndexedNode {
  desc: NodeDesc;
  extra: { index: number },
  comment: string | null;
  // FIMXE: how do we handle default inputs?
  inputs: Input[],
  outputs: (Output | null)[];
}

export type NodeId = number;

export type JsNode = ReactFlowNode<{
  type: string;
  comment?: string | null;
  isEntry?: boolean;
  inputs: (JsInput | null)[];
  outputs: (JsOutput | null)[];
}>;

export type JsEdge = ReactFlowEdge<{}>;

/**
 * A graph which simultaneously provides a recloned immutable node/edges state pair
 * for e.g. react, and a native grappl graph between operations
 */
export class GrapplGraph {
  _nativeGraphBuilder: native.JsGraphBuilder = undefined;
  _nodeMap = new Map<NodeId, JsNode>();
  _nodeStateProxy = [] as JsNode[];
  _edgeStateProxy = [] as JsEdge[];

  private constructor() {}

  static async create(): Promise<GrapplGraph> {
    const result = new GrapplGraph();
    result._nativeGraphBuilder = await native.JsGraphBuilder.init();
    return result;
  }

  async addNode(kind: string, is_entry: boolean = false): Promise<NodeId> {
    const node = await this._nativeGraphBuilder.makeNode(kind);
    // FIXME: use u32 because this is a bigint!
    const nodeId = Number(await this._nativeGraphBuilder.addNode(node, is_entry));
    this._updateJsProxyAddNode(nodeId, node, is_entry);
    return nodeId;
  }

  private _updateJsProxyAddNode(nodeId: NodeId, node: IndexedNode, isEntry: boolean) {
    const jsNode = {
      // TODO: consider number?
      id: `${nodeId}`,
      data: {
        type: (node.desc.name as any).string,
        isEntry,
        comment: null,
        inputs: new Array(node.desc.getInputs().length).fill(null),
        outputs: new Array(node.desc.getOutputs().length).fill(null),
      },
      position: {
        // FIXME: naive
        x: 100 * this._nodeStateProxy.length,
        y: 0
      },
    };
    this._nodeStateProxy = [...this._nodeStateProxy, jsNode];
    this._nodeMap.set(nodeId, jsNode);
  }

  async addEdge(source_id: NodeId, src_out_pin: number, target_id: NodeId, target_in_pin: number): Promise<void> {
    const edge = this._nativeGraphBuilder.addEdge(source_id, src_out_pin, target_id, target_in_pin);
    this._updateJsProxyAddEdge(source_id, src_out_pin, target_id, target_in_pin);
    return edge;
  }

  private _updateJsProxyAddEdge(source_id: NodeId, src_out_pin: number, target_id: NodeId, target_in_pin: number): void {
    const source = this._nodeMap.get(source_id);
    if (source === undefined)
      throw Error("source doesn't exist");

    const target = this._nodeMap.get(target_id);
    if (target === undefined)
      throw Error("target doesn't exist");

    // TODO: handle auto replace somewhere
    if (target.data.inputs[target_in_pin] !== null)
      throw Error("target input already connected");

    const sourceHandle = `${source_id}_true_${src_out_pin}`;
    const targetHandle = `${target_id}_true_${target_in_pin}`;

    // FIXME: should we keep track of outputs this way? One node can connect to multiple things potentially
    //source.outputs[src_out_pin] = 
    target.data.inputs[target_in_pin] = {
      link: {
        target: source,
        targetId: source_id,
        pin_index: src_out_pin,
        sub_index: 0
      }
    };

    this._edgeStateProxy = [
      ...this._edgeStateProxy,
      {
        source: String(source_id),
        sourceHandle,
        target: String(target_id),
        targetHandle,
        id: `ed-${sourceHandle}-${targetHandle}`,
      }
    ];

  }

  private _updateJsProxyLiteral(source_id: NodeId, src_in_pin: number, value: ZigValue): void {
    const source = this._nodeMap.get(source_id);
    if (source === undefined)
      throw Error("source doesn't exist");

    // TODO: handle auto replace somewhere
    if (source.data.inputs[src_in_pin] !== null)
      throw Error("source input already connected");

    const cloned = structuredClone(source);
    cloned.data.inputs[src_in_pin] = { value: value };

    this._nodeMap.set(source_id, cloned);
    this._nodeStateProxy = this._nodeStateProxy.map(n => n.id === `${source_id}` ? cloned : n);
  }

  async addLiteral(source_id: NodeId, src_in_pin: number, value: ZigValue): Promise<void> {
    const implOrThrow = () => {
      switch (typeof value) {
        case "boolean":
          return this._nativeGraphBuilder.addBoolLiteral(source_id, src_in_pin, value);
        case "string":
          return this._nativeGraphBuilder.addStringLiteral(source_id, src_in_pin, value);
        case "number":
        case "bigint":
          return this._nativeGraphBuilder.addFloatLiteral(source_id, src_in_pin, value);
        // TODO: consider using js symbols lol?
        case "object": {
          if (value === null)
            throw Error("null value not supported yet");
          if ("symbol" in value) {
            return this._nativeGraphBuilder.addSymbolLiteral(source_id, src_in_pin, value.symbol);
          }
        }
      }

      throw Error(`unsupported value ${value}`)
    };

    await implOrThrow();
    this._updateJsProxyLiteral(source_id, src_in_pin, value);
  }

  async compile(): Promise<string> {
    return (await this._nativeGraphBuilder.compile()).string;
  }

  get reactState() {
    return this._nodeStateProxy;
  }

}
