import React from "react";
import { GrapplGraph, JsEdge, JsNode } from "./GrapplGraph";

export interface GrapplContext {
  graph: {
    addNode: GrapplGraph["addNode"];
    addEdge: GrapplGraph["addEdge"];
    addLiteral: GrapplGraph["addLiteral"];
  }
  nodes: JsNode[];
  edges: JsEdge[];
}

export const defaultGrapplContext: GrapplContext = new Proxy({} as GrapplContext, {
  get() { throw Error("GrapplContext must have a provider"); },
});

export const GrapplContext = React.createContext(defaultGrapplContext);

export function GrapplProvider(props: React.PropsWithChildren<{}>) {
  const graphRef = React.useRef<GrapplGraph>(undefined as any as GrapplGraph);
  const [nodes, setNodes] = React.useState<JsNode[]>([]);
  const [edges, setEdges] = React.useState<JsEdge[]>([]);

  const addNode: GrapplGraph["addNode"] = React.useCallback((...args) => {
    const result = graphRef.current.addNode(...args);
    setNodes(graphRef.current._nodeStateProxy);
    return result;
  }, []);

  const addEdge: GrapplGraph["addEdge"] = React.useCallback((...args) => {
    const result = graphRef.current.addEdge(...args);
    setNodes(graphRef.current._nodeStateProxy);
    setEdges(graphRef.current._edgeStateProxy);
    return result;
  }, []);

  const addLiteral: GrapplGraph["addLiteral"] = React.useCallback((...args) => {
    const result = graphRef.current.addLiteral(...args);
    setNodes(graphRef.current._nodeStateProxy);
    return result;
  }, []);

  const graph = React.useMemo(() => ({
    addNode,
    addEdge,
    addLiteral,
  }), [addNode, addEdge, addLiteral]);

  const value = React.useMemo(() => {
    // FIXME: race condition!
    if (graphRef.current === undefined)
      GrapplGraph.create().then(g => { graphRef.current = g; });

    return {
      nodes,
      edges,
      graph,
    };
  }, [nodes, edges, graph]);

  return (
    <GrapplContext.Provider value={value}>
      {props.children}
    </GrapplContext.Provider>
  );
}

