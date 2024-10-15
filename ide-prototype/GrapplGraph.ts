import native from "../lang-lib/src/main.zig";
import { Node as ReactFlowNode } from "reactflow";

export type ZigValue =
| { number: number }
| { string: string }
| { bool: boolean }
| { null: undefined }
| { symbol: string };


export interface Link {
  target: unknown;
  pin_index: number;
  sub_index: number;
}

export interface Input {
  link: Link;
  value: ZigValue;
}

export interface Output {
  link: Link;
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

type JsNode = ReactFlowNode<{
  type: string;
  comment?: string | null;
  isEntry?: boolean;
}>;

/**
 * */
export class GrapplGraph {
  _nativeGraphBuilder = native.JsGraphBuilder.init();
  _nodeMap = new Map<NodeId, JsNode>();
  _nodeStateProxy = [] as JsNode[];
  _edges = [];

  addNode(kind: string, is_entry: boolean = false): NodeId {
    const node = this._nativeGraphBuilder.makeNode(kind);
    const nodeId = this._nativeGraphBuilder.addNode(node, is_entry);
    this._addJsNodeProxy(nodeId, node);
    return nodeId;
  }

  private _addJsNodeProxy(nodeId: NodeId, node: IndexedNode) {
    const jsNode = {
      id: "0",
      data: {
        type: (node.desc.name as any).string,
        isEntry: true,
        comment: null
      },
      position: {
        // FIXME: naive
        x: 100 * this._nodeStateProxy.length,
        y: 0
      },
      inputs: new Array(node.desc.getInputs().length).fill(null),
      outputs: new Array(node.desc.getOutputs().length).fill(null),
    };
    this._nodeStateProxy.push(jsNode);
    this._nodeMap.set(nodeId, jsNode);
  }

  addEdge(source_id: NodeId, src_out_pin: number, target_id: NodeId, target_in_pin: number): void {
    return this._nativeGraphBuilder.addEdge(source_id, src_out_pin, target_id, target_in_pin);
  }

  addBoolLiteral(source_id: NodeId, src_in_pin: number, value: boolean): void {
    return this._nativeGraphBuilder.addBoolLiteral(source_id, src_in_pin, value);
  }

  addFloatLiteral(source_id: NodeId, src_in_pin: number, value: number): void {
    return this._nativeGraphBuilder.addFloatLiteral(source_id, src_in_pin, value);
  }

  addStringLiteral(source_id: NodeId, src_in_pin: number, value: string): void {
    return this._nativeGraphBuilder.addStringLiteral(source_id, src_in_pin, value);
  }

  addSymbolLiteral(source_id: NodeId, src_in_pin: number, value: string): void {
    return this._nativeGraphBuilder.addSymbolLiteral(source_id, src_in_pin, value);
  }

  compile(): string {
    return this._nativeGraphBuilder.compile().string;
  }

  get reactState() {
    return this._nodeStateProxy;
  }

}
