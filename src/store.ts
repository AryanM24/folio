import { useSyncExternalStore } from 'react'
import type { DocState, Obj, Page, Tool } from './lib/types'
import { relayoutObjects } from './lib/geometry'

export interface Style {
  stroke: string
  fill: string
  strokeWidth: number
  opacity: number
  fontSize: number
  sticky: string
}

export interface State {
  docId: string | null
  name: string
  doc: DocState
  past: DocState[]
  future: DocState[]
  selection: string[]
  tool: Tool
  style: Style
  view: { x: number; y: number; zoom: number }
  editingId: string | null
  activePage: string | null
  signature: string | null
  hits: { pageId: string; x: number; y: number; w: number; h: number }[]
  spaceDown: boolean
}

const initial: State = {
  docId: null,
  name: '',
  doc: { pages: [], objects: [] },
  past: [],
  future: [],
  selection: [],
  tool: 'select',
  style: { stroke: '#1f2937', fill: 'transparent', strokeWidth: 3, opacity: 1, fontSize: 18, sticky: '#fde68a' },
  view: { x: 0, y: 0, zoom: 1 },
  editingId: null,
  activePage: null,
  signature: null,
  hits: [],
  spaceDown: false,
}

let state = initial
const subs = new Set<() => void>()
export const getState = () => state
export function setState(patch: Partial<State> | ((s: State) => Partial<State>)) {
  state = { ...state, ...(typeof patch === 'function' ? patch(state) : patch) }
  subs.forEach((f) => f())
}
export const subscribe = (f: () => void) => (subs.add(f), () => subs.delete(f))
export function useStore<T>(sel: (s: State) => T): T {
  return useSyncExternalStore(subscribe, () => sel(state))
}

// ---------------- history ----------------
const MAX_HISTORY = 100

/** Snapshot the current doc so the next change(s) can be undone. */
export function checkpoint() {
  setState((s) => ({ past: [...s.past.slice(-MAX_HISTORY + 1), s.doc], future: [] }))
}
/** Change the doc without a history entry (use during drags, after checkpoint()). */
export function setDoc(fn: (d: DocState) => DocState) {
  setState((s) => ({ doc: fn(s.doc) }))
}
/** Change the doc as one undoable step. */
export function commit(fn: (d: DocState) => DocState) {
  checkpoint()
  setDoc(fn)
}
export function undo() {
  setState((s) => {
    const prev = s.past.at(-1)
    if (!prev) return {}
    return { doc: prev, past: s.past.slice(0, -1), future: [s.doc, ...s.future], selection: [], editingId: null }
  })
}
export function redo() {
  setState((s) => {
    const [next, ...rest] = s.future
    if (!next) return {}
    return { doc: next, past: [...s.past, s.doc], future: rest, selection: [], editingId: null }
  })
}

// ---------------- object helpers ----------------
export const updateObjects = (ids: string[], fn: (o: Obj) => Obj) =>
  commit((d) => ({ ...d, objects: d.objects.map((o) => (ids.includes(o.id) ? fn(o) : o)) }))

export function addObject(o: Obj, select = true) {
  commit((d) => ({ ...d, objects: [...d.objects, o] }))
  if (select) setState({ selection: [o.id] })
}

export function deleteSelection() {
  const { selection } = state
  if (!selection.length) return
  commit((d) => ({ ...d, objects: d.objects.filter((o) => !selection.includes(o.id) || o.locked) }))
  setState({ selection: [], editingId: null })
}

export function reorder(dir: 'front' | 'back' | 'forward' | 'backward') {
  const sel = new Set(state.selection)
  commit((d) => {
    const objs = [...d.objects]
    if (dir === 'front') return { ...d, objects: [...objs.filter((o) => !sel.has(o.id)), ...objs.filter((o) => sel.has(o.id))] }
    if (dir === 'back') return { ...d, objects: [...objs.filter((o) => sel.has(o.id)), ...objs.filter((o) => !sel.has(o.id))] }
    const step = dir === 'forward' ? 1 : -1
    const idx = objs.map((o, i) => (sel.has(o.id) ? i : -1)).filter((i) => i >= 0)
    for (const i of step > 0 ? idx.reverse() : idx) {
      const j = i + step
      if (j < 0 || j >= objs.length || sel.has(objs[j].id)) continue
      ;[objs[i], objs[j]] = [objs[j], objs[i]]
    }
    return { ...d, objects: objs }
  })
}

/** Replace the page list, carrying objects along with their pages. */
export function setPages(fn: (p: Page[]) => Page[]) {
  commit((d) => {
    const pages = fn(d.pages)
    return { pages, objects: relayoutObjects(d.pages, pages, d.objects) }
  })
}

export const setTool = (tool: Tool) => setState({ tool, editingId: null, ...(tool !== 'select' ? { selection: [] } : {}) })
export const setStyle = (p: Partial<Style>) => setState((s) => ({ style: { ...s.style, ...p } }))

export function resetEditor(docId: string, name: string, doc: DocState) {
  setState({ ...initial, style: state.style, signature: state.signature, docId, name, doc, activePage: doc.pages[0]?.id ?? null })
}

// ---------------- viewport ----------------
let viewportEl: HTMLElement | null = null
export const setViewportEl = (el: HTMLElement | null) => { viewportEl = el }
export const MIN_ZOOM = 0.1, MAX_ZOOM = 8

export function zoomAt(zoom: number, sx?: number, sy?: number) {
  const r = viewportEl?.getBoundingClientRect()
  const ax = sx ?? (r ? r.width / 2 : 0), ay = sy ?? (r ? r.height / 2 : 0)
  setState((s) => {
    const z = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom))
    const k = z / s.view.zoom
    return { view: { zoom: z, x: ax - (ax - s.view.x) * k, y: ay - (ay - s.view.y) * k } }
  })
}

/** Centre a world-space box in the viewport. */
export function fitBox(b: { x: number; y: number; w: number; h: number }, pad = 64, maxZoom = 2) {
  const r = viewportEl?.getBoundingClientRect()
  if (!r) return
  const zoom = Math.min(maxZoom, (r.width - pad * 2) / b.w, (r.height - pad * 2) / b.h)
  setState({ view: { zoom, x: r.width / 2 - (b.x + b.w / 2) * zoom, y: r.height / 2 - (b.y + b.h / 2) * zoom } })
}

/** Scroll so the box's top sits near the top of the viewport, keeping zoom. */
export function revealBox(b: { x: number; y: number; w: number; h: number }) {
  const r = viewportEl?.getBoundingClientRect()
  if (!r) return
  setState((s) => ({ view: { ...s.view, x: r.width / 2 - (b.x + b.w / 2) * s.view.zoom, y: 80 - b.y * s.view.zoom } }))
}

export function viewCenterWorld(): [number, number] {
  const r = viewportEl?.getBoundingClientRect()
  const { x, y, zoom } = state.view
  return r ? [(r.width / 2 - x) / zoom, (r.height / 2 - y) / zoom] : [0, 0]
}
