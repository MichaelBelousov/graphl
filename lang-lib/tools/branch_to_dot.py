#!/usr/bin/env python

import sys, os

print(f"digraph {os.environ.get('GRAPH_NAME', 'G')} {{")

edges = []

for line in sys.stdin:
  if line.startswith("from:"):
    from_, to = line.strip().split("->")
    from_ = from_.replace("from:", "")
    to = to.replace("to:", "")
    edges.append((from_, to))
    print(f"_{from_} -> _{to};")
  elif line.startswith("to:"):
    pass

print("}")
