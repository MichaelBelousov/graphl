import React from 'react'
import ReactFlow, {
  addEdge,
  Elements,
  Handle,
  NodeProps,
  Node,
  removeElements,
  Controls,
  MiniMap,
  isEdge,
  EdgeProps,
  getBezierPath,
  getMarkerEnd,
  getSmoothStepPath,
} from 'react-flow-renderer'
import styles from './DialogueEditor.module.scss'
import { downloadFile, uploadFile } from '../utils/localFileManip'

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

const initial: Elements<{} | DialogueEntryNodeData> = [
  {
    id: '1',
    type: 'input',
    data: {
      label: 'entry',
    },
    position: { x: 540, y: 100 },
  },
]

interface AppState {
  /** map of portrait file name to its [data]url */
  portraits: Map<string, string>
}

const AppCtx = React.createContext<AppState>(
  new Proxy({} as AppState, {
    get() {
      throw Error('cannot consume null context')
    },
  })
)

const DialogueEntryNode = (props: NodeProps<DialogueEntryNodeData>) => {
  const appCtx = React.useContext(AppCtx)
  return (
    <div className={styles.dialogueEntryNode}>
      <Handle
        type="target"
        position="top"
        className={styles.handle}
        isConnectable
      />
      <label>
        portrait
        <select
          onChange={e =>
            props.data.onChange({ portrait: e.currentTarget.value })
          }
        >
          {[...appCtx.portraits]
            .map(([imageName]) => (
              <option value={imageName}>{imageName}</option>
            ))
            .concat(<option>none</option>)}
        </select>
        {props.data.portrait && (
          <img
            className={styles.portraitImg}
            src={appCtx.portraits.get(props.data.portrait)}
            alt={props.data.portrait}
          />
        )}
      </label>
      <label>
        title
        <input
          className="nodrag"
          onChange={e =>
            props.data.onChange({ ...props.data, title: e.currentTarget.value })
          }
          defaultValue={props.data.title}
        />
      </label>
      <label>
        text
        <textarea
          className="nodrag"
          onChange={e =>
            props.data.onChange({ ...props.data, text: e.currentTarget.value })
          }
          defaultValue={props.data.text}
        />
      </label>
      <button onClick={props.data.onDelete} className={styles.deleteButton}>
        &times;
      </button>
      {/* will dynamically add handles potentially... */}
      <Handle
        type="source"
        position="bottom"
        className={styles.handle}
        isConnectable
      />
    </div>
  )
}

enum nodeTypeNames {
  dialogueEntry = 'dialogueEntry',
}

const nodeTypes = {
  // TODO: could just make this the "default" node
  [nodeTypeNames.dialogueEntry]: DialogueEntryNode,
} as const

const CustomDefaultEdge = (props: EdgeProps) => {
  const edgePath = getSmoothStepPath(props)
  const markerEnd = getMarkerEnd(props.arrowHeadType, props.markerEndId)
  return (
    <>
      <path
        id={props.id}
        style={{ ...props.style, strokeWidth: 3 }}
        className="react-flow__edge-path"
        d={edgePath}
        markerEnd={markerEnd}
      />
    </>
  )
}

const edgeTypes = {
  // TODO: could just make this the "default" node
  default: CustomDefaultEdge,
} as const

const DialogueEditor = () => {
  const [elements, setElements] = React.useState(initial)
  const onRightClick = React.useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault()
      const newId = `${Math.round(Math.random() * Number.MAX_SAFE_INTEGER)}`
      setElements(prev =>
        prev.concat({
          id: newId,
          type: nodeTypeNames.dialogueEntry,
          data: {
            title: 'test title',
            text: 'test text',
            onChange: (newVal: Partial<DialogueEntryNodeData>) =>
              setElements(prev => {
                const copy = prev.slice()
                const index = copy.findIndex(elem => elem.id === newId)
                const elem = copy[index]
                copy[index] = {
                  ...elem,
                  data: {
                    ...elem.data,
                    ...newVal,
                  },
                }
                return copy
              }),
            onDelete: () =>
              setElements(prev =>
                removeElements(
                  prev.filter(e => e.id === newId),
                  prev
                )
              ),
          },
          position: { x: e.clientX - 0, y: e.clientY - 50 },
        } as Node<DialogueEntryNodeData>)
      )
    },
    [setElements]
  )

  const [portraits, setPortraits] = React.useState(new Map<string, string>())

  return (
    <div className={styles.page} onContextMenu={onRightClick}>
      <div className={styles.toolbar}>
        <button
          onClick={() => {
            downloadFile({
              fileName: 'out.dialogue.json',
              content: JSON.stringify(elements),
            })
          }}
        >
          Save
        </button>
        <button
          onClick={async () => {
            const file = await uploadFile({ type: 'text' })
            const json = JSON.parse(file.content)
            setElements(json)
          }}
        >
          Load
        </button>
        <button
          onClick={async () => {
            const file = await uploadFile({ type: 'dataurl' })
            setPortraits(prev => new Map([...prev, [file.name, file.content]]))
          }}
        >
          Upload Portrait
        </button>
      </div>
      {/* TODO: must memoize the context value */}
      <AppCtx.Provider value={{ portraits }}>
        <div className={styles.graph}>
          <ReactFlow
            elements={elements}
            onConnect={params => setElements(e => addEdge(params, e))}
            onElementsRemove={toRemove =>
              setElements(e => removeElements(toRemove, e))
            }
            deleteKeyCode={46} /*DELETE key*/
            snapToGrid
            snapGrid={[15, 15]}
            nodeTypes={nodeTypes}
            edgeTypes={edgeTypes}
            onElementClick={(_evt, elem) => {
              if (isEdge(elem)) {
                setElements(elems => removeElements([elem], elems))
              }
            }}
          >
            <Controls />
            <MiniMap />
          </ReactFlow>
        </div>
      </AppCtx.Provider>
    </div>
  )
}

export default DialogueEditor
