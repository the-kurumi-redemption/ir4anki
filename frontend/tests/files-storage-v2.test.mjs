import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import ts from 'typescript'

const source = readFileSync(new URL('../src/components/FilesScreen.tsx', import.meta.url), 'utf8')
const ast = ts.createSourceFile('FilesScreen.tsx', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)

function declaration(name) {
  let code
  function walk(n) {
    if (ts.isFunctionDeclaration(n) && n.name?.text === name) code = n.getText(ast)
    ts.forEachChild(n, walk)
  }
  walk(ast)
  assert.ok(code, 'Actual handler absent: ' + name)
  return code
}

const create = (names, context, prelude = '') =>
  new Function(
    ...Object.keys(context),
    ts.transpileModule(prelude + names.map(declaration).join('\n'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022 },
    }).outputText + `;return {${names}}`
  )(...Object.values(context))

// 1. Verify UI wiring in FilesScreen.tsx
assert.ok(source.includes('回收站'), 'FilesScreen must render Recycle Bin button/dialog')
assert.ok(source.includes('历史版本'), 'FilesScreen must render Revision History button/dialog')
assert.ok(source.includes('全文检索匹配'), 'FilesScreen must render FTS5 search results section')

// 2. Test Trash open / restore / empty handlers
let trashOpen = false
let trashBusy = false
let trashData = { notebooks: [], notes: [] }
let message = ''
let reloads = 0
let restoredCalls = []
let emptied = 0

const trashCtx = {
  alive: true,
  busy: () => false,
  trashBusy: () => trashBusy,
  setTrashOpen: v => (trashOpen = v),
  setTrashBusy: v => (trashBusy = v),
  setTrashData: v => (trashData = v),
  setMessage: v => (message = v),
  reload: async () => {
    reloads++
  },
  document: { activeElement: null },
  api: {
    storageTrash: async () => ({
      notebooks: [{ id: 'nb1', title: 'FolderA', parent_id: null, pos: 0, created_at: 1, updated_at: 2, deleted_at: 3 }],
      notes: [{ id: 'n1', title: 'NoteA.md', notebook_id: null, body_sha: 'abc', in_list: false, list_pos: 0, needs_resync: false, created_at: 1, updated_at: 2, deleted_at: 3 }],
    }),
    storageTrashRestore: async (kind, id) => {
      restoredCalls.push({ kind, id })
      return { ok: true }
    },
    storageTrashEmpty: async () => {
      emptied++
      return { ok: true }
    },
  },
}

const { openTrash, restoreTrashItem, emptyTrash } = create(
  ['openTrash', 'restoreTrashItem', 'emptyTrash'],
  trashCtx,
  'let returnFocus=null;'
)

await openTrash()
assert.equal(trashOpen, true)
assert.equal(trashBusy, false)
assert.equal(trashData.notebooks.length, 1)
assert.equal(trashData.notes.length, 1)

await restoreTrashItem('note', 'n1')
assert.deepEqual(restoredCalls, [{ kind: 'note', id: 'n1' }])
assert.equal(reloads, 1)
assert.equal(message, '已从回收站恢复')

await emptyTrash()
assert.equal(emptied, 1)
assert.deepEqual(trashData, { notebooks: [], notes: [] })
assert.equal(message, '回收站已清空')

// 3. Test Revision History open / select / rollback handlers
let revOpen = false
let revBusy = false
let revList = []
let revDetail = null
let invalidated = []
let versions = 0

const revCtx = {
  alive: true,
  busy: () => false,
  revBusy: () => revBusy,
  requestDraftLeave: () => true,
  setRevOpen: v => (revOpen = v),
  setRevBusy: v => (revBusy = v),
  setRevList: v => (revList = v),
  setRevDetail: v => (revDetail = v),
  setMessage: v => (message = v),
  setVersion: fn => (versions = fn(versions)),
  invalidateFileCache: p => invalidated.push(p),
  reload: async () => {
    reloads++
  },
  restoreFocus: () => {},
  document: { activeElement: null },
  api: {
    noteRevisions: async path => ({
      revisions: [
        { id: 2, note_id: 'n1', title: path, body_sha: '22222222', reason: 'edit', created_at: 200, byte_length: 12 },
        { id: 1, note_id: 'n1', title: path, body_sha: '11111111', reason: 'overwrite', created_at: 100, byte_length: 10 },
      ],
    }),
    noteRevisionDetail: async (path, revId) => ({
      id: revId,
      note_id: 'n1',
      title: path,
      body_sha: revId === 2 ? '22222222' : '11111111',
      reason: 'edit',
      created_at: 100 * revId,
      byte_length: 10,
      body: `body-v${revId}`,
    }),
    noteRevisionRestore: async (path, revId) => ({ ok: true, id: revId }),
  },
}

const { openRevisions, selectRevision, rollbackRevision } = create(
  ['openRevisions', 'selectRevision', 'rollbackRevision'],
  revCtx,
  'let returnFocus=null;'
)

await openRevisions('folder/note.md')
assert.equal(revOpen, true)
assert.equal(revList.length, 2)
assert.equal(revDetail.id, 2)
assert.equal(revDetail.body, 'body-v2')

await selectRevision('folder/note.md', 1)
assert.equal(revDetail.id, 1)
assert.equal(revDetail.body, 'body-v1')

await rollbackRevision('folder/note.md', 1)
assert.equal(revOpen, false)
assert.deepEqual(invalidated, ['folder/note.md'])
assert.equal(versions, 1)
assert.equal(message, '已回滚至版本 #1')

console.log('PASS Storage v2 Recycle Bin and Note Revision History handlers and UI wiring')
