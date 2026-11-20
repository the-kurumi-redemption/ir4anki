import { createSignal } from 'solid-js'
import { api } from '../api'
import type { AiAnnotation } from '../types'

// Stand-off AI Highlight & Comment Overlay Layer (原文零污染旁路高亮图层).
//
// Design guarantees:
// 1. Zero source Markdown mutation: `notes.body` and `segments.fingerprint`
//    stay 100% pure.
// 2. High robustness against user edits and Markdown formatting:
//    - Matches `quote_exact` across arbitrary inline DOM boundaries (`<strong>`,
//      `<em>`, `span.line` from `annotateLines`, inline code).
//    - Falls back to a skeleton-normalized stream match (stripping Markdown
//      syntax, whitespace, and CJK/ASCII punctuation differences) so even if
//      the rendered DOM text differs from raw Markdown or the user edited
//      formatting/punctuation, the highlight still lands cleanly.
//    - Disambiguates repeated short phrases using `quote_prefix` and
//      `quote_suffix`.
// 3. Always-expanded comment bars (option B): annotations with non-empty
//    `comment` render a superscript badge (`①`, `②`, …) at the end of the
//    highlighted span and an always-visible callout bar directly below the
//    containing paragraph/list-item block, carrying `data-ai-layer="true"`
//    so line-handle splitting and cloze selection ignore it.
// 4. Clean reversible toggle: `clearAiLayer(root)` unwraps `<mark class="ai-hl">`
//    and removes `[data-ai-layer]` elements without disturbing `annotateLines`
//    handles (`span.line` / `.line-handle`).

const STORAGE_KEY = 'ir4anki-ai-layer-enabled-v1'

function readInitialEnabled(): boolean {
  try {
    const v = localStorage.getItem(STORAGE_KEY)
    return v === null ? true : v === 'true'
  } catch {
    return true
  }
}

const [aiLayerEnabled, setAiLayerEnabledSignal] = createSignal<boolean>(readInitialEnabled())

export { aiLayerEnabled }

export function setAiLayerEnabled(next: boolean): boolean {
  setAiLayerEnabledSignal(next)
  try {
    localStorage.setItem(STORAGE_KEY, String(next))
  } catch {
    /* ignore storage quota errors */
  }
  return next
}

export function toggleAiLayer(): boolean {
  return setAiLayerEnabled(!aiLayerEnabled())
}

// ---- Per-path annotation cache with invalidation ----
const annotationCache = new Map<string, Promise<AiAnnotation[]>>()
const listeners = new Set<(path?: string) => void>()

export function fetchNoteAnnotations(path: string): Promise<AiAnnotation[]> {
  if (!path || typeof window === 'undefined' || typeof globalThis.fetch !== 'function') {
    return Promise.resolve([])
  }
  const hit = annotationCache.get(path)
  if (hit) return hit
  const p = api
    .noteAnnotations(path)
    .then(r => (Array.isArray(r?.annotations) ? r.annotations : []))
    .catch(() => {
      annotationCache.delete(path)
      return [] as AiAnnotation[]
    })
  annotationCache.set(path, p)
  return p
}

export function invalidateAiAnnotations(path?: string): void {
  if (!path) {
    annotationCache.clear()
  } else {
    annotationCache.delete(path)
  }
  for (const fn of listeners) fn(path)
}

export function observeAiAnnotations(fn: (path?: string) => void): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

// ---- DOM Text-Stream & Skeleton Matcher ----

const SKIP_CHARS_RE = /[\s\*_`~#\>\-\+\|\[\]\(\)!，。、；：？！“”‘’（）【】《》〈〉「」『』—…·,.;:?!\"'\\]/

function isSkippableChar(ch: string): boolean {
  return SKIP_CHARS_RE.test(ch)
}

interface TextSegment {
  node: Text
  start: number
  end: number
}

function collectTextStream(root: HTMLElement): { fullText: string; segments: TextSegment[] } {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const parent = node.parentElement
      if (!parent) return NodeFilter.FILTER_REJECT
      if (
        parent.closest(
          '[data-ai-layer], .line-handle, .katex-mathml, script, style',
        )
      ) {
        return NodeFilter.FILTER_REJECT
      }
      return NodeFilter.FILTER_ACCEPT
    },
  })

  const segments: TextSegment[] = []
  const parts: string[] = []
  let offset = 0
  let cur = walker.nextNode() as Text | null
  while (cur) {
    const val = cur.nodeValue || ''
    if (val.length > 0) {
      segments.push({ node: cur, start: offset, end: offset + val.length })
      parts.push(val)
      offset += val.length
    }
    cur = walker.nextNode() as Text | null
  }
  return { fullText: parts.join(''), segments }
}

function buildSkeleton(text: string): { skel: string; map: number[] } {
  const chars: string[] = []
  const map: number[] = []
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (isSkippableChar(ch)) continue
    chars.push(ch.toLowerCase())
    map.push(i)
  }
  return { skel: chars.join(''), map }
}

function scoreContext(
  fullSkel: string,
  matchSkelStart: number,
  matchSkelEnd: number,
  prefixSkel: string,
  suffixSkel: string,
): number {
  let score = 0
  if (prefixSkel) {
    const actualPrefix = fullSkel.slice(
      Math.max(0, matchSkelStart - prefixSkel.length),
      matchSkelStart,
    )
    if (actualPrefix === prefixSkel) {
      score += 2
    } else if (actualPrefix.endsWith(prefixSkel.slice(-8)) || prefixSkel.endsWith(actualPrefix.slice(-8))) {
      score += 1
    }
  }
  if (suffixSkel) {
    const actualSuffix = fullSkel.slice(
      matchSkelEnd,
      Math.min(fullSkel.length, matchSkelEnd + suffixSkel.length),
    )
    if (actualSuffix === suffixSkel) {
      score += 2
    } else if (actualSuffix.startsWith(suffixSkel.slice(0, 8)) || suffixSkel.startsWith(actualSuffix.slice(0, 8))) {
      score += 1
    }
  }
  return score
}

interface ResolvedMatch {
  ann: AiAnnotation
  startOffset: number
  endOffset: number
}

function findQuoteInStream(
  fullText: string,
  fullSkel: string,
  skelMap: number[],
  ann: AiAnnotation,
): { startOffset: number; endOffset: number } | null {
  const rawQuote = (ann.quote_exact || '').trim()
  if (!rawQuote || !fullText) return null

  const prefixSkel = buildSkeleton(ann.quote_prefix || '').skel
  const suffixSkel = buildSkeleton(ann.quote_suffix || '').skel

  // Tier 1: Direct substring match in rendered text
  const exactHits: { start: number; end: number }[] = []
  let pos = 0
  while (pos <= fullText.length - rawQuote.length) {
    const idx = fullText.indexOf(rawQuote, pos)
    if (idx < 0) break
    exactHits.push({ start: idx, end: idx + rawQuote.length })
    pos = idx + 1
  }
  if (exactHits.length === 1) {
    return { startOffset: exactHits[0].start, endOffset: exactHits[0].end }
  }
  if (exactHits.length > 1) {
    // Disambiguate using prefix/suffix
    let best = exactHits[0]
    let bestScore = -1
    for (const h of exactHits) {
      const pText = buildSkeleton(fullText.slice(Math.max(0, h.start - 40), h.start)).skel
      const sText = buildSkeleton(fullText.slice(h.end, Math.min(fullText.length, h.end + 40))).skel
      let sc = 0
      if (prefixSkel && pText.endsWith(prefixSkel.slice(-10))) sc += 2
      if (suffixSkel && sText.startsWith(suffixSkel.slice(0, 10))) sc += 2
      if (sc > bestScore) {
        bestScore = sc
        best = h
      }
    }
    return { startOffset: best.start, endOffset: best.end }
  }

  // Tier 2: Skeleton-normalized match (handles stripped Markdown **bold**, soft newlines, punctuation)
  const quoteSkel = buildSkeleton(rawQuote).skel
  if (!quoteSkel || !fullSkel) return null

  const skelHits: { skelStart: number; skelEnd: number }[] = []
  pos = 0
  while (pos <= fullSkel.length - quoteSkel.length) {
    const idx = fullSkel.indexOf(quoteSkel, pos)
    if (idx < 0) break
    skelHits.push({ skelStart: idx, skelEnd: idx + quoteSkel.length })
    pos = idx + 1
  }
  if (!skelHits.length) return null

  let bestHit = skelHits[0]
  let bestScore = -1
  for (const h of skelHits) {
    const sc = scoreContext(fullSkel, h.skelStart, h.skelEnd, prefixSkel, suffixSkel)
    if (sc > bestScore) {
      bestScore = sc
      bestHit = h
    }
  }

  const startOffset = skelMap[bestHit.skelStart]
  const endOffset = skelMap[bestHit.skelEnd - 1] + 1
  return { startOffset, endOffset }
}

const CIRCLED_NUMS = [
  '①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩',
  '⑪', '⑫', '⑬', '⑭', '⑮', '⑯', '⑰', '⑱', '⑲', '⑳',
]

function badgeLabel(index1: number): string {
  return CIRCLED_NUMS[index1 - 1] || `[${index1}]`
}

/** Remove all AI highlight `<mark class="ai-hl">` wrappers and `[data-ai-layer]`
 *  comment bars from `root`, restoring clean text nodes without losing
 *  `span.line` or `.line-handle` annotations. */
export function clearAiLayer(root: HTMLElement): void {
  if (!root || typeof root.querySelectorAll !== 'function') return
  // 1. Remove injected badges and comment callout bars
  for (const el of Array.from(root.querySelectorAll('[data-ai-layer]'))) {
    el.remove()
  }
  // 2. Unwrap <mark class="ai-hl"> elements and normalize adjacent text nodes
  const parentsToNormalize = new Set<Node>()
  for (const mark of Array.from(root.querySelectorAll('mark.ai-hl'))) {
    const parent = mark.parentNode
    if (!parent) continue
    while (mark.firstChild) {
      parent.insertBefore(mark.firstChild, mark)
    }
    parent.removeChild(mark)
    parentsToNormalize.add(parent)
  }
  for (const p of parentsToNormalize) {
    ;(p as Element).normalize?.()
  }
}

function findContainingBlock(node: Node, root: HTMLElement): HTMLElement {
  let cur: Node | null = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
  let fallbackBlock: HTMLElement | null = null
  while (cur && cur !== root) {
    if (cur.nodeType === Node.ELEMENT_NODE) {
      const el = cur as HTMLElement
      if (/^(P|LI|H[1-6]|BLOCKQUOTE|PRE|TABLE| DIV)$/i.test(el.tagName)) {
        if (el.dataset.srcLine || /^(P|LI|H[1-6]|BLOCKQUOTE)$/i.test(el.tagName)) {
          return el
        }
        if (!fallbackBlock) fallbackBlock = el
      }
    }
    cur = cur.parentNode
  }
  return fallbackBlock || root
}

/** Apply stand-off AI highlights and always-visible block comment bars to `root`.
 *  Returns the number of annotations that matched inside `root`. */
export function applyAiLayer(
  root: HTMLElement,
  annotations: AiAnnotation[],
  enabled: boolean,
): number {
  clearAiLayer(root)
  if (!enabled || !annotations || annotations.length === 0) return 0

  const activeAnns = annotations.filter(a => a.status === 'active' && (a.quote_exact || '').trim())
  if (activeAnns.length === 0) return 0

  const { fullText, segments } = collectTextStream(root)
  if (!fullText || segments.length === 0) return 0
  const { skel: fullSkel, map: skelMap } = buildSkeleton(fullText)

  const resolved: ResolvedMatch[] = []
  for (const ann of activeAnns) {
    const hit = findQuoteInStream(fullText, fullSkel, skelMap, ann)
    if (hit && hit.endOffset > hit.startOffset) {
      resolved.push({ ann, startOffset: hit.startOffset, endOffset: hit.endOffset })
    }
  }
  if (resolved.length === 0) return 0

  // Sort in document order and deduplicate exact overlapping ranges
  resolved.sort((a, b) => a.startOffset - b.startOffset || b.endOffset - a.endOffset)

  let commentCounter = 0
  const blockComments = new Map<
    HTMLElement,
    { badge: string; comment: string; layerName: string; annId: string }[]
  >()

  for (const match of resolved) {
    const { ann, startOffset, endOffset } = match
    const hasComment = Boolean((ann.comment || '').trim())
    const badge = hasComment ? badgeLabel(++commentCounter) : ''

    // Re-collect current text stream because previous wraps split text nodes
    const currentStream = collectTextStream(root)
    const overlapping = currentStream.segments.filter(
      s => s.end > startOffset && s.start < endOffset,
    )
    if (overlapping.length === 0) continue

    let lastMark: HTMLElement | null = null
    // Process in reverse order so splitting earlier nodes doesn't shift later segments
    for (let i = overlapping.length - 1; i >= 0; i--) {
      const seg = overlapping[i]
      const localStart = Math.max(0, startOffset - seg.start)
      const localEnd = Math.min(seg.node.nodeValue?.length ?? 0, endOffset - seg.start)
      if (localEnd <= localStart) continue

      let targetNode = seg.node
      if (localEnd < (targetNode.nodeValue?.length ?? 0)) {
        targetNode.splitText(localEnd)
      }
      if (localStart > 0) {
        targetNode = targetNode.splitText(localStart)
      }

      // Skip whitespace-only inter-block text nodes
      if (!(targetNode.nodeValue || '').trim() && overlapping.length > 1) {
        continue
      }

      const mark = document.createElement('mark')
      mark.className = 'ai-hl'
      mark.dataset.annId = ann.id
      if (ann.layer_name && ann.layer_name !== 'default') {
        mark.dataset.layer = ann.layer_name
      }
      targetNode.parentNode?.insertBefore(mark, targetNode)
      mark.appendChild(targetNode)
      if (!lastMark) lastMark = mark
    }

    if (lastMark && hasComment) {
      const sup = document.createElement('sup')
      sup.className = 'ai-hl-badge'
      sup.dataset.aiLayer = 'true'
      sup.textContent = badge
      lastMark.appendChild(sup)

      const block = findContainingBlock(lastMark, root)
      const list = blockComments.get(block) ?? []
      list.push({
        badge,
        comment: ann.comment.trim(),
        layerName: ann.layer_name || 'default',
        annId: ann.id,
      })
      blockComments.set(block, list)
    }
  }

  // Render always-visible AI comment callout bars directly under their containing blocks
  for (const [block, items] of blockComments.entries()) {
    const container = document.createElement('div')
    container.className = 'ai-comment-stack'
    container.dataset.aiLayer = 'true'
    container.setAttribute('contenteditable', 'false')

    for (const item of items) {
      const bar = document.createElement('div')
      bar.className = 'ai-comment-bar'
      bar.dataset.aiLayer = 'true'
      bar.dataset.annId = item.annId

      const badgeEl = document.createElement('span')
      badgeEl.className = 'ai-comment-badge'
      badgeEl.textContent = item.badge
      bar.appendChild(badgeEl)

      const textEl = document.createElement('span')
      textEl.className = 'ai-comment-text'
      textEl.textContent = item.comment
      bar.appendChild(textEl)

      if (item.layerName && item.layerName !== 'default') {
        const tagEl = document.createElement('span')
        tagEl.className = 'ai-comment-layer'
        tagEl.textContent = item.layerName
        bar.appendChild(tagEl)
      }

      container.appendChild(bar)
    }

    if (block.tagName === 'LI') {
      // Inside a <li>, append at the bottom of the <li> so it stays indented with the list item
      block.appendChild(container)
    } else if (block !== root && block.parentNode) {
      block.parentNode.insertBefore(container, block.nextSibling)
    } else {
      root.appendChild(container)
    }
  }

  return resolved.length
}
