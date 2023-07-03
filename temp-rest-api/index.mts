import child_process from 'node:child_process';
import express from 'express';
import * as addon from './addon.mjs'

const app = express()
const port = 3001

app.get('/graph_to_source', (req: express.Request, res: express.Response) => {
  res.send(addon.graph_to_source(req.body))
})

app.get('/source_to_graph', (req: express.Request, res: express.Response) => {
  res.send(addon.source_to_graph(req.body))
})

app.listen(port, () => {
  console.log(`Listening on port ${port}`)
})
