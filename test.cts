import { GrapplGraph, JsNode } from "./ide-prototype/GrapplGraph";
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
    g.addLiteral(plus_index, 1, 4.0);
    g.addEdge(entry_index, 0, set_index, 0);
    g.addLiteral(set_index, 1, { symbol: "x" });
    g.addEdge(plus_index, 0, set_index, 2);

    const src = g.compile();

    const expected = `\
(set! x
      (+ actor-location
         4))`

    function normalizeNode(node: JsNode): JsNode {
      return {
        ...node,
        data: {
          ...node.data,
          inputs: node.data.inputs.map(i => {
            if (i !== null && "link" in i) {
              const result = { ...i, link: { ...i.link } };
              result.link.pin_index = Number(result.link.pin_index);
              delete result.link.target;
              delete result.link.sub_index;
              return result;
            } else {
              return i;
            }
          }),
        }
      };
    }

    assert.strictEqual(src, expected);

    assert.strictEqual(g["_nodeStateProxy"].length, 4);

    assert.deepStrictEqual(normalizeNode(g["_nodeStateProxy"][0]), {
      id: `${entry_index}`,
      data: {
        type: "CustomTickEntry",
        isEntry: true,
        comment: null,
        inputs: [],
        outputs: [
          null, //{ link: { targetId: 3, pin_index: 0 } },
        ],
      },
      position: {
        x: 0,
        y: 0
      },
    } satisfies JsNode);

    assert.deepStrictEqual(normalizeNode(g["_nodeStateProxy"][1]), {
      id: String(plus_index),
      data: {
        type: "+",
        isEntry: false,
        comment: null,
        inputs: [
          { link: { targetId: 2, pin_index: 0 } },
          { value: 4.0 },
        ],
        outputs: [
          null, //{ link: { targetId: "2", pin_index: 0 } },
        ]
      },
      position: {
        x: 100,
        y: 0
      },
    } satisfies JsNode);

    assert.deepStrictEqual(normalizeNode(g["_nodeStateProxy"][2]), {
      id: `${actor_loc_index}`,
      data: {
        type: "#GET#actor-location",
        isEntry: false,
        comment: null,
        inputs: [],
        outputs: [
          //{ link: { targetId: 1, pin_index: 0 }}
          null
        ],
      },
      position: {
        x: 200,
        y: 0
      },
    } satisfies JsNode);

    console.log(3)
    assert.deepStrictEqual(normalizeNode(g["_nodeStateProxy"][3]), {
      id: `${set_index}`,
      data: {
        type: "set!",
        isEntry: false,
        comment: null,
        inputs: [
          { link: { targetId: entry_index, pin_index: 0 } },
          { value: { symbol: "x" } },
          { link: { targetId: plus_index, pin_index: 0 } },
        ],
        outputs: [
          null,
          null,
        ],
      },
      position: {
        x: 300,
        y: 0
      },
    } satisfies JsNode);

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


