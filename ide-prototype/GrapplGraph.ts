import native from "../lang-lib/src/main.zig";

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

export class GrapplGraph {
  _nativeGraphBuilder = native.JsGraphBuilder.init();
  _nodes = [];
  _edges = [];

  makeNode(kind: string): IndexedNode {
    return this._nativeGraphBuilder.makeNode(kind);
  }

  addNode(node: IndexedNode, is_entry: boolean = false): NodeId {
    return this._nativeGraphBuilder.addNode(node, is_entry);
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
}
