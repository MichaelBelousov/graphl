import { GrapplGraph } from "./ide-prototype/GrapplGraph";
import { describe, it } from "node:test";
import assert from "node:assert";

describe("grappl-js", function () {
  it("small", () => {
    const g = new GrapplGraph();

    const entry_index = g.addNode("CustomTickEntry", true);
    const plus_index = g.addNode("+");
    const actor_loc_index = g.addNode("#GET#actor-location");
    const set_index = g.addNode("set!");

    g.addEdge(actor_loc_index, 0, plus_index, 0);
    g.addFloatLiteral(plus_index, 1, 4.0);
    g.addEdge(entry_index, 0, set_index, 0);
    g.addSymbolLiteral(set_index, 1, "x");
    g.addEdge(plus_index, 0, set_index, 2);

    const src = g.compile();

    const expected = `\
(set! x
      (+ actor-location
         4))`

    assert.strictEqual(src, expected);
    assert.deepStrictEqual(g["_nodeStateProxy"], [
      {
        id: "0",
        data: {
          type: "CustomTickEntry",
          isEntry: true,
          comment: null
        },
        position: {
          x: 0,
          y: 0
        },
        inputs: [],
        outputs: [
          {
            nodeId: "3",
            handleIndex: 0
          }
        ]
      },
      {
        id: "1",
        data: {
          type: "+",
          isEntry: false,
          comment: null
        },
        position: {
          x: 100,
          y: 0
        },
        inputs: [
          { link: { nodeId: "2", handleIndex: 0 } },
          { value: { number: 4.0 } },
        ],
        outputs: [
          { link: { nodeId: "2", handleIndex: 0 } },
        ]
      },
      {
        id: "2",
        data: {
          type: "#GET#actor-location",
          isEntry: false,
          comment: null
        },
        position: {
          x: 200,
          y: 0
        },
        outputs: [
          { link: { nodeId: "1", handleIndex: 0 }}
        ]
      },
      {
        id: "3",
        data: {
          type: "set!",
          isEntry: false,
          comment: null
        },
        position: {
          x: 300,
          y: 0
        },
        inputs: [
          { value: { symbol: "x" } },
          { link: { nodeId: "1", handleIndex: 1 } },
        ],
        outputs: [
          null
        ]
      },
    ]);

    assert.deepStrictEqual(g._edges, [
      {
        source: "3349452269105633",
        sourceHandle: "3349452269105633_true_0",
        target: "1786967944785462",
        targetHandle: "1786967944785462_false_0",
        id: "reactflow__edge-33494522691056333349452269105633_true_0-17869679447854621786967944785462_false_0"
      },
    ]);
  });
});


