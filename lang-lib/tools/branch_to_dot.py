#!/usr/bin/env python

import sys, os


edges = []
label_to_node = {}
node_to_label = {}

def getOrAddNode(label: str) -> int:
  id = label_to_node.get(label)
  if id is not None:
    return id

  id = len(node_to_label)
  node_to_label[id] = label
  label_to_node[label] = id
  return id

from_ = None
to = None

for line in sys.stdin:
  # if "->" in line and line.startswith("from:"):
  if "->" not in line and line.startswith("from:"):
    from_ = getOrAddNode(line[len("from:"):-1])
  elif "->" not in line and line.startswith("to:"):
    to = getOrAddNode(line[len("to:"):-1])

  if from_ and to:
    edges.append((from_, to))
    from_ = None
    to = None

print("digraph G {")
for node, label in node_to_label.items():
  print(f'  _{node} [label="{label}"]')
for left, right in edges:
  print(f"  _{left} -> _{right};")
print("}")
