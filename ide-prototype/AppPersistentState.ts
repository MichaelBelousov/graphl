import type { Node, Edge } from 'reactflow'

interface DialogueEntry {
  portrait?: string
  title: string
  text: string
}

interface DialogueEntryNodeData extends DialogueEntry {
  /** shallow merges in a patch to the data for that entry */
  onChange(newData: Partial<DialogueEntry>): void
  onDelete(): void
}

interface PersistentData {
  initialNodes: Node<{} | DialogueEntryNodeData>[];
  initialEdges: Edge<{}>[];
  editorProgram: string;
}

const defaultPersistentData: PersistentData = {
  initialNodes: [{
    id: '1',
    type: 'input',
    data: {
      label: 'entry',
    },
    position: { x: 540, y: 100 },
  }],
  initialEdges: [],
  editorProgram: "(define (++ x) (set! x (+ 1 x)))",
};

export const persistentData = new Proxy({} as any as PersistentData, {
  get(obj, key: keyof PersistentData, recv) {
    if (!(key in obj)) {
      const persisted = localStorage.getItem(key);
      obj[key] = persisted
        ? JSON.parse(persisted)
        : defaultPersistentData[key];
    }
    return Reflect.get(obj, key, recv);
  },
  set(obj, key: keyof PersistentData, value, recv) {
    localStorage.setItem(key, JSON.stringify(value));
    return Reflect.set(obj, key, value, recv)
  }
});

