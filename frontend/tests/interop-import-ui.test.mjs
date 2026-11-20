import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import ts from 'typescript'
import { ApiError, UploadConflictError, UploadPartialError, api } from '../src/api.ts'
import { SerialBatch } from '../src/lib/files-browser.ts'

globalThis.crypto ??= (await import('node:crypto')).webcrypto

const source = readFileSync(new URL('../src/components/FilesScreen.tsx', import.meta.url), 'utf8')
const ast = ts.createSourceFile('FilesScreen.tsx', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)

function declaration(name) {
  let code
  function walk(n) {
    if (ts.isFunctionDeclaration(n) && n.name?.text === name) code = n.getText(ast)
    ts.forEachChild(n, walk)
  }
  walk(ast)
  assert.ok(code, 'Handler missing: ' + name)
  return code
}

const build = (names, context) =>
  new Function(
    ...Object.keys(context),
    ts.transpileModule(names.map(declaration).join('\n'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022 },
    }).outputText + `;return {${names}}`
  )(...Object.values(context))

// 1. Verify FilesScreen renders warnings panel
assert.ok(source.includes('fb-import-warnings'), 'FilesScreen must render collapsible import warnings panel')

// 2. Verify importEntries consumes Joplin InteropResult summary, server skipped items, warnings, and renamed paths
let message = ''
let skippedList = [{ rel: 'book/manifest.json', reason: '不支持的文件类型，不导入' }]
let warningsList = []
const invalidated = []
let reloads = 0

const ctx = {
  alive: true,
  busy: () => false,
  requestDraftLeave: () => true,
  setWorking() {},
  setMessage: v => { message = v },
  setSkippedImports: fn => { skippedList = typeof fn === 'function' ? fn(skippedList) : fn },
  setImportWarnings: v => { warningsList = v },
  setImportConflict() {},
  UploadConflictError,
  UploadPartialError,
  ApiError,
  batch: new SerialBatch(() => {}),
  api: {
    async filesUpload() {
      return {
        ok: true,
        imported_notes: [
          { note_id: 'n1', path: '2026/book/001 (1).md', original: 'book/001.md', action: 'renamed', title: '001 (1)', resources_linked: 2 },
        ],
        imported_resources: [
          { resource_id: 'r1', original: 'book/_assets/a.png', filename: 'a.png', reused: false },
          { resource_id: 'r2', original: 'book/_assets/b.png', filename: 'b.png', reused: true },
        ],
        skipped: [
          { path: 'book/_assets/unused.png', reason: '未被任何笔记正文引用，未入库' },
        ],
        warnings: ['book/001.md: 未找到本地图片引用 missing.png'],
        summary: {
          notes_imported: 1,
          notes_written: 0,
          notes_overwritten: 0,
          notes_renamed: 1,
          notes_skipped: 0,
          resources_imported: 2,
          resources_new: 1,
          resources_reused: 1,
          skipped: 1,
          warnings: 1,
        },
        saved: [{ path: '2026/book/001 (1).md', action: 'renamed', original: 'book/001.md' }],
        images_renamed: {},
      }
    },
  },
  invalidateFileCache: p => invalidated.push(p),
  window: { dispatchEvent() {} },
  Event: class {},
  setVersion() {},
  reload: async () => { reloads++ },
}

const { importEntries } = build(['importEntries'], ctx)
await importEntries(
  [{ file: { name: '001.md' }, rel: 'book/001.md' }, { file: { name: 'a.png' }, rel: 'book/_assets/a.png' }],
  '2026',
  'rename',
)

assert.equal(reloads, 1)
assert.ok(message.includes('已导入 1 篇笔记'), message)
assert.ok(message.includes('2 张图片（其中 1 张去重复用）'), message)
assert.ok(message.includes('跳过 1 项'), message)
assert.ok(message.includes('1 条告警'), message)
assert.equal(skippedList.length, 2, 'backend skipped items merged with frontend skipped items')
assert.equal(skippedList[1].rel, 'book/_assets/unused.png')
assert.deepEqual(warningsList, ['book/001.md: 未找到本地图片引用 missing.png'])
assert.ok(invalidated.includes('2026/book/001 (1).md'), 'renamed note destination cache invalidated')

// 3. Verify api.interopModules & api.interopImport client helpers
let lastUrl = ''
globalThis.fetch = async url => {
  lastUrl = String(url)
  if (lastUrl.includes('/api/interop/modules')) {
    return new Response(JSON.stringify({ modules: [{ format: 'md', description: 'Markdown', file_extensions: ['.md'], supports_directory: true }] }), { status: 200 })
  }
  return new Response(JSON.stringify({ detail: JSON.stringify({ conflicts: ['a.md'] }) }), { status: 409 })
}
const mods = await api.interopModules()
assert.equal(mods.modules[0].format, 'md')
await assert.rejects(() => api.interopImport([], '2026', 'error'), e => e instanceof UploadConflictError && e.conflicts[0] === 'a.md')

console.log('PASS interop P0 UI summary, skipped/warnings merge, cache invalidation, and interop API helpers')
