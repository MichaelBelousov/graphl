import { GrapplGraph, JsNode } from "./ide-prototype/GrapplGraph";
import { describe, it } from "node:test";
import assert from "node:assert";

describe("grappl-js", function () {
  it("small", async () => {
    const g = await GrapplGraph.create();

    const entry_index = await g.addNode("CustomTickEntry", true);
    const plus_index = await g.addNode("+");
    const actor_loc_index = await g.addNode("#GET#actor-location");
    const set_index = await g.addNode("set!");

    await g.addEdge(actor_loc_index, 0, plus_index, 0);
    await g.addLiteral(plus_index, 1, 4.0);
    await g.addEdge(entry_index, 0, set_index, 0);
    await g.addLiteral(set_index, 1, { symbol: "x" });
    await g.addEdge(plus_index, 0, set_index, 2);

    const src = await g.compile();

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

    assert.deepStrictEqual(g["_edgeStateProxy"], [
      {
        source: String(actor_loc_index),
        sourceHandle: `${actor_loc_index}_true_0`,
        target: String(plus_index),
        targetHandle: `${plus_index}_true_0`,
        id: `ed-${actor_loc_index}_true_0-${plus_index}_true_0`
      },
      {
        source: String(entry_index),
        sourceHandle: `${entry_index}_true_0`,
        target: String(set_index),
        targetHandle: `${set_index}_true_0`,
        id: `ed-${entry_index}_true_0-${set_index}_true_0`
      },
      {
        source: String(plus_index),
        sourceHandle: `${plus_index}_true_0`,
        target: String(set_index),
        targetHandle: `${set_index}_true_2`,
        id: `ed-${plus_index}_true_0-${set_index}_true_2`
      },
    ]);
  });
});
