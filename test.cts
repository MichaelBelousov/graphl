import { GrapplGraph } from "./ide-prototype/GrapplGraph";

const g = new GrapplGraph();

const entry_index = g.addNode(g.makeNode("CustomTickEntry"), true);
const plus_index = g.addNode(g.makeNode("+"));
const actor_loc_index = g.addNode(g.makeNode("#GET#actor-location"));
const set_index = g.addNode(g.makeNode("set!"));

g.addEdge(actor_loc_index, 0, plus_index, 0);
g.addFloatLiteral(plus_index, 1, 4.0);
g.addEdge(entry_index, 0, set_index, 0);
g.addSymbolLiteral(set_index, 1, "x");
g.addEdge(plus_index, 0, set_index, 2);

const src = g.compile();
console.log(src);

