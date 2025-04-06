#!/usr/bin/env python

import sys


edges = []
node_to_label = {}

def getOrAddNode(key, label: str):
  blk_side, id = key
  node_to_label[key] = f"{blk_side}/{id}: {label}"

from_ = None
to = None

for line in sys.stdin:
  dir, _, rest = line.partition(':')
  blk_side, _, rest = rest.partition(':')
  id, _, rest = rest.partition(':')

  if dir not in ("from", "to") or blk_side not in ("pre", "post"):
    continue

  if dir == "from":
    from_ = (blk_side, id)
    getOrAddNode(from_, rest.strip())

  elif dir == "to":
    to = (blk_side, id)
    getOrAddNode(to, rest.strip())

  if from_ is not None and to is not None:
    edges.append((from_, to))
    from_ = None
    to = None

ranked = set()
print("digraph G {")
for (blk_side, id), label in node_to_label.items():
  try:
    if id not in ranked:
      ranked.add(id)
      other = ('pre' if blk_side == 'post' else 'post', label)
      print(f'  subgraph cluster_{id} {{ _{blk_side}_{id}; _{other[0]}_{id} }}')
  except KeyError:
    pass
  print(f'  _{blk_side}_{id} [label="{label}"]')
for (lblk, left), (rblk, right) in edges:
  print(f"  _{lblk}_{left} -> _{rblk}_{right};")
print("}")
