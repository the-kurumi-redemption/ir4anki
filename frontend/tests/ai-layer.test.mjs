import assert from 'node:assert/strict'
import { createSignal } from 'solid-js'
import { pathToFileURL } from 'node:url'
import { root, render, createComponent, find } from './split-renderer.mjs'

// Minimal DOM tree implementation for testing applyAiLayer / clearAiLayer
// across nested elements (span.line, strong, .line-handle, p, li).
class MiniNode {
  constructor(nodeType) {
    this.nodeType = nodeType
    this.parentNode = null
    this.childNodes = []
  }
  get parentElement() {
    return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null
  }
  get firstChild() {
    return this.childNodes[0] ?? null
  }
  get nextSibling() {
    if (!this.parentNode) return null
    const i = this.parentNode.childNodes.indexOf(this)
    return i >= 0 && i + 1 < this.parentNode.childNodes.length
      ? this.parentNode.childNodes[i + 1]
      : null
  }
  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child)
    child.parentNode = this
    this.childNodes.push(child)
    return child
  }
  insertBefore(newNode, refNode) {
    if (!refNode) return this.appendChild(newNode)
    if (newNode.parentNode) newNode.parentNode.removeChild(newNode)
    const idx = this.childNodes.indexOf(refNode)
    if (idx < 0) return this.appendChild(newNode)
    newNode.parentNode = this
    this.childNodes.splice(idx, 0, newNode)
    return newNode
  }
  removeChild(child) {
    const idx = this.childNodes.indexOf(child)
    if (idx >= 0) {
      this.childNodes.splice(idx, 1)
      child.parentNode = null
    }
    return child
  }
  remove() {
    if (this.parentNode) this.parentNode.removeChild(this)
  }
}

class MiniText extends MiniNode {
  constructor(text) {
    super(3)
    this.nodeValue = String(text)
  }
  get textContent() {
    return this.nodeValue
  }
  set textContent(v) {
    this.nodeValue = String(v)
  }
  splitText(offset) {
    const head = this.nodeValue.slice(0, offset)
    const tail = this.nodeValue.slice(offset)
    this.nodeValue = head
    const next = new MiniText(tail)
    if (this.parentNode) {
      this.parentNode.insertBefore(next, this.nextSibling)
    }
    return next
  }
}

function matchesSelector(el, sel) {
  if (!el || el.nodeType !== 1) return false
  const parts = sel.split(',').map(s => s.trim()).filter(Boolean)
  for (const part of parts) {
    if (part === '[data-ai-layer]') {
      if (el.dataset.aiLayer !== undefined) return true
    } else if (part === 'mark.ai-hl') {
      if (el.tagName === 'MARK' && el.classList.contains('ai-hl')) return true
    } else if (part === '.ai-comment-bar') {
      if (el.classList.contains('ai-comment-bar')) return true
    } else if (part === '.ai-hl-badge') {
      if (el.classList.contains('ai-hl-badge')) return true
    } else if (part === '.line-handle') {
      if (el.classList.contains('line-handle')) return true
    } else if (part === '.katex-mathml') {
      if (el.classList.contains('katex-mathml')) return true
    } else if (part === 'script' || part === 'style') {
      if (el.tagName === part.toUpperCase()) return true
    } else if (part.startsWith('.')) {
      if (el.classList.contains(part.slice(1))) return true
    }
  }
  return false
}

class MiniElement extends MiniNode {
  constructor(tagName) {
    super(1)
    this.tagName = tagName.toUpperCase()
    this.dataset = {}
    this.attrs = {}
    this._classes = new Set()
    const self = this
    this.classList = {
      add(...cls) { cls.forEach(c => c && self._classes.add(c)) },
      remove(...cls) { cls.forEach(c => self._classes.delete(c)) },
      contains(c) { return self._classes.has(c) },
      toggle(c, force) {
        const next = force !== undefined ? force : !self._classes.has(c)
        if (next) self._classes.add(c)
        else self._classes.delete(c)
        return next
      },
    }
  }
  get className() {
    return Array.from(this._classes).join(' ')
  }
  set className(v) {
    this._classes = new Set(String(v).split(/\s+/).filter(Boolean))
  }
  setAttribute(k, v) {
    this.attrs[k] = String(v)
  }
  get textContent() {
    return this.childNodes.map(c => c.textContent).join('')
  }
  set textContent(v) {
    this.childNodes = []
    if (v !== '' && v !== null && v !== undefined) {
      this.appendChild(new MiniText(String(v)))
    }
  }
  closest(sel) {
    let cur = this
    while (cur && cur.nodeType === 1) {
      if (matchesSelector(cur, sel)) return cur
      cur = cur.parentElement
    }
    return null
  }
  querySelectorAll(sel) {
    const out = []
    const walk = node => {
      for (const ch of node.childNodes) {
        if (ch.nodeType === 1) {
          if (matchesSelector(ch, sel)) out.push(ch)
          walk(ch)
        }
      }
    }
    walk(this)
    return out
  }
  normalize() {
    let i = 0
    while (i < this.childNodes.length) {
      const cur = this.childNodes[i]
      if (cur.nodeType === 3) {
        if (cur.nodeValue === '') {
          this.removeChild(cur)
          continue
        }
        while (i + 1 < this.childNodes.length && this.childNodes[i + 1].nodeType === 3) {
          cur.nodeValue += this.childNodes[i + 1].nodeValue
          this.removeChild(this.childNodes[i + 1])
        }
      } else if (cur.nodeType === 1) {
        cur.normalize()
      }
      i++
    }
  }
}

globalThis.Node = { ELEMENT_NODE: 1, TEXT_NODE: 3 }
globalThis.NodeFilter = {
  SHOW_TEXT: 4,
  FILTER_ACCEPT: 1,
  FILTER_REJECT: 2,
  FILTER_SKIP: 3,
}
globalThis.document = {
  addEventListener() {},
  removeEventListener() {},
  createElement(tag) {
    return new MiniElement(tag)
  },
  createTextNode(text) {
    return new MiniText(text)
  },
  createTreeWalker(rootEl, _whatToShow, filter) {
    const textNodes = []
    const walk = node => {
      for (const ch of node.childNodes) {
        if (ch.nodeType === 3) {
          const res = filter?.acceptNode ? filter.acceptNode(ch) : 1
          if (res === 1) textNodes.push(ch)
        } else if (ch.nodeType === 1) {
          walk(ch)
        }
      }
    }
    walk(rootEl)
    let idx = 0
    return {
      nextNode() {
        return idx < textNodes.length ? textNodes[idx++] : null
      },
    }
  },
}

const srcRoot = process.env.SPLIT_SOURCE_ROOT ?? process.cwd() + '/src'
const {
  aiLayerEnabled,
  setAiLayerEnabled,
  applyAiLayer,
  clearAiLayer,
} = await import(pathToFileURL(srcRoot + '/lib/ai-layer.ts'))
const { ReadingCard } = await import(pathToFileURL(srcRoot + '/components/ReadingCard.tsx'))

// 1. Test ReadingCard toolbar button presence & toggle reactivity
const host = root()
const [busy] = createSignal(false)
const [chunk] = createSignal({
  kind: 'markdown',
  path: 'test.md',
  chunk_key: 'k1',
  seg_id: 1,
  status: 'todo',
  heading_path: ['第一章'],
  line_start: 1,
  text: '第一行内容\n第二行核心考点',
  cards_created: [],
})

setAiLayerEnabled(true)
const dispose = render(
  () =>
    createComponent(ReadingCard, {
      get chunk() { return chunk() },
      get busy() { return busy() },
      onEdit() {},
      onComplete() {},
      onNext() {},
      onSkip() {},
      onExit() {},
      onAdd() {},
      onCloze() {},
      onSplit: () => true,
    }),
  host,
)
await Promise.resolve()

const toggleBtn = () =>
  find(host, n => n.tag === 'md-icon-button' && n.props['data-ai-layer-toggle'] !== undefined)
assert.ok(toggleBtn(), 'ReadingCard toolbar must contain AI layer toggle button')
assert.equal(toggleBtn().props['aria-pressed'], true)
assert.match(toggleBtn().props.class, /ai-layer-toggle--on/)

toggleBtn().props.onClick()
assert.equal(aiLayerEnabled(), false)
assert.equal(toggleBtn().props['aria-pressed'], false)
assert.doesNotMatch(toggleBtn().props.class, /ai-layer-toggle--on/)

toggleBtn().props.onClick()
assert.equal(aiLayerEnabled(), true)
assert.equal(toggleBtn().props['aria-pressed'], true)
dispose()

// 2. Test applyAiLayer & clearAiLayer across span.line, inline formatting, and repeated quotes
const container = new MiniElement('div')

// Paragraph 1 with span.line, .line-handle, and <strong> formatting (simulating user edit + annotateLines)
const p1 = new MiniElement('p')
p1.dataset.srcLine = '1-2'
const line1 = new MiniElement('span')
line1.className = 'line'
line1.dataset.lineStart = '1'
line1.dataset.lineEnd = '1'
const handle1 = new MiniElement('button')
handle1.className = 'line-handle'
handle1.textContent = '•'
line1.appendChild(handle1)
line1.appendChild(new MiniText('正常组织受照射后出现'))
const strong = new MiniElement('strong')
strong.textContent = '早反应与晚反应'
line1.appendChild(strong)
line1.appendChild(new MiniText('两种模式。'))
p1.appendChild(line1)
container.appendChild(p1)

// Paragraph 2 & 3 with repeated phrase "核心机制" to test prefix/suffix disambiguation
const p2 = new MiniElement('p')
p2.dataset.srcLine = '4-4'
p2.appendChild(new MiniText('甲通路中的核心机制是自由基损伤。'))
container.appendChild(p2)

const p3 = new MiniElement('p')
p3.dataset.srcLine = '6-6'
p3.appendChild(new MiniText('乙通路中的核心机制是DNA双链断裂修复障碍。'))
container.appendChild(p3)

const annotations = [
  {
    id: 'ann_1',
    note_id: 'note_1',
    layer_name: '学长重点',
    // Original quote had markdown asterisks or slightly different punctuation; skeleton matcher resolves across <strong>
    quote_exact: '出现**早反应与晚反应**两种模式',
    quote_prefix: '正常组织受照射后',
    quote_suffix: '。',
    comment: '2023名词解释真题：区分早反应组织与晚反应组织的α/β比值差异。',
    line_hint: 1,
    status: 'active',
    created_at: 1,
    updated_at: 1,
  },
  {
    id: 'ann_2',
    note_id: 'note_1',
    layer_name: '学长重点',
    quote_exact: '核心机制',
    quote_prefix: '乙通路中的',
    quote_suffix: '是DNA双链断裂',
    comment: '简答题高频采分点',
    line_hint: 6,
    status: 'active',
    created_at: 1,
    updated_at: 1,
  },
]

const count = applyAiLayer(container, annotations, true)
assert.equal(count, 2, 'Both annotations should resolve and highlight')

// Verify <mark class="ai-hl"> spans were created without polluting .line-handle
const marks = container.querySelectorAll('mark.ai-hl')
assert.ok(marks.length >= 2, 'Should wrap matched spans in <mark class="ai-hl">')

// Verify disambiguation: p2 should NOT contain a highlight, p3 MUST contain the highlight for "核心机制"
assert.equal(p2.querySelectorAll('mark.ai-hl').length, 0, 'Prefix/suffix should prevent highlighting wrong occurrence in p2')
assert.equal(p3.querySelectorAll('mark.ai-hl').length, 1, 'Correct occurrence in p3 should be highlighted')

// Verify superscript badges ① and ② and always-visible comment bars
const badges = container.querySelectorAll('.ai-hl-badge')
assert.equal(badges.length, 2)
assert.equal(badges[0].textContent, '①')
assert.equal(badges[1].textContent, '②')

const commentBars = container.querySelectorAll('.ai-comment-bar')
assert.equal(commentBars.length, 2)
assert.match(commentBars[0].textContent, /①/)
assert.match(commentBars[0].textContent, /2023名词解释真题/)
assert.match(commentBars[1].textContent, /②/)
assert.match(commentBars[1].textContent, /简答题高频采分点/)

// Verify clearAiLayer cleanly unwraps highlights and removes comment bars while keeping .line-handle and span.line
clearAiLayer(container)
assert.equal(container.querySelectorAll('mark.ai-hl').length, 0)
assert.equal(container.querySelectorAll('[data-ai-layer]').length, 0)
assert.equal(container.querySelectorAll('.line-handle').length, 1)
assert.equal(p1.textContent, '•正常组织受照射后出现早反应与晚反应两种模式。')
assert.equal(p3.textContent, '乙通路中的核心机制是DNA双链断裂修复障碍。')

console.log('PASS ai-layer: toolbar toggle, cross-element skeleton highlight, prefix/suffix disambiguation, always-visible comment bar, and reversible cleanup')
