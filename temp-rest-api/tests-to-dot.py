#!/usr/bin/env python

import json
import sys
from subprocess import run

if __name__ == '__main__':
    node_data = json.load(sys.stdin)

    outputs = {}
    for n in node_data["nodes"]:
        for o in node_data["outputs"]:
            outputs[o] = n

    nodes = { n:f"{n.type}-{i}" for i, n in enumerate(node_data["nodes"])}
    edges = []

    for n in node_data["nodes"]:
        for i in n["inputs"]:
            edges.append((outputs[i], n))

    dot_proc = run(["dot", "-Tsvg"], input=bytes(f'''
                   digraph graph {{
                       {"".join((f"{a} -> {b};" for a,b in edges))}
                   }}
                   ''', 'utf8'), capture_output=True);

    sys.stderr.buffer.write(dot_proc.stderr)
    sys.stdout.buffer.write(dot_proc.stdout)


