#!/usr/bin/env python

import json
import sys
from subprocess import run
from textwrap import dedent

if __name__ == '__main__':
    node_data = json.load(sys.stdin)

    outputs = {}
    for ni, n in enumerate(node_data["nodes"]):
        for o in n.get("outputs", []):
            outputs[o] = ni

    # nodes = { n.items():n["type"]+f"-{i}" for i, n in enumerate(node_data["nodes"])}
    nodes = { i:f'{n["type"]} (#{i})' for i, n in enumerate(node_data["nodes"])}
    edges = []

    for ni, n in enumerate(node_data["nodes"]):
        for i in n.get("inputs", []):
            if isinstance(i, int):
                edges.append((outputs[i], ni))

    NL = "\n"
    graph_src = dedent(f'''
        digraph out {{
            {(NL + " "*12).join((f'"{nodes[a]}" -> "{nodes[b]}";' for a,b in edges))}
        }}
    ''')

    dot_proc = run(["dot", "-Tsvg"], input=bytes(graph_src, 'utf8'), capture_output=True);

    sys.stderr.buffer.write(dot_proc.stderr)
    sys.stdout.buffer.write(dot_proc.stdout)


