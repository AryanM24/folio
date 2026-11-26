import { useEffect, useMemo, useRef, useState } from 'react'
import type { Box, DocState, Obj, Pt, StickyObj, TextObj } from '../lib/types'
import { bbox, FONT, intersects, layout, LINE_H, moveObj, resizeObj, unionBox } from '../lib/geometry'
import { uid } from '../lib/storage'
import {
  addObject, checkpoint, getState, setDoc, setState, setViewportEl, useStore, zoomAt, commit,
} from '../store'
import { ObjectView, STICKY_PAD } from './ObjectView'
import { PageView } from './PageView'
import { importFiles } from '../lib/files'

type Drag =
  | { kind: 'pan'; sx: number; sy: number; vx: number; vy: number }
  | { kind: 'move'; start: Pt; orig: Obj[]; moved: boolean; alt: boolean }
  | { kind: 'resize'; start: Pt; handle: string; box: Box; orig: Obj[]; moved: boolean }
  | { kind: 'marquee'; start: Pt; add: string[] }
  | { kind: 'draw'; start: Pt }
  | { kind: 'erase'; checked: boolean }

const HANDLES = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'] as const
const CURSORS: Record<string, string> = { nw: 'nwse-resize', se: 'nwse-resize', ne: 'nesw-resize', sw: 'nesw-resize', n: 'ns-resize', s: 'ns-resize', e: 'ew-resize', w: 'ew-resize' }

export function Canvas() {
  const ref = useRef<HTMLDivElement>(null)
  const pages = useStore((s) => s.doc.pages)
  const objects = useStore((s) => s.doc.objects)
  const view = useStore((s) => s.view)
  const tool = useStore((s) => s.tool)
  const selection = useStore((s) => s.selection)
  const editingId = useStore((s) => s.editingId)
  const activePage = useStore((s) => s.activePage)
  const hits = useStore((s) => s.hits)
  const spaceDown = useStore((s) => s.spaceDown)

  const lay = useMemo(() => layout(pages), [pages])
  const [drag, setDrag] = useState<Drag | null>(null)
  const [draft, setDraft] = useState<Obj | null>(null)
  const [marquee, setMarquee] = useState<Box | null>(null)

  useEffect(() => { setViewportEl(ref.current); return () => setViewportEl(null) }, [])

  // track which page is nearest the viewport centre
  useEffect(() => {
    const r = ref.current?.getBoundingClientRect()
    if (!r) return
    const cy = (r.height / 2 - view.y) / view.zoom
    let best: string | null = null, bd = Infinity
    for (const [id, b] of lay) {
      const d = Math.abs(b.y + b.h / 2 - cy)
      if (d < bd) { bd = d; best = id }
    }
    if (best !== getState().activePage) setState({ activePage: best })
  }, [view, lay])

  // wheel: pan, pinch/ctrl to zoom. Non-passive so we can preventDefault.
  useEffect(() => {
    const el = ref.current!
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      const r = el.getBoundingClientRect()
      const { view } = getState()
      if (e.ctrlKey || e.metaKey) {
        zoomAt(view.zoom * Math.exp(-e.deltaY * 0.01), e.clientX - r.left, e.clientY - r.top)
      } else {
        setState({ view: { ...view, x: view.x - (e.shiftKey ? e.deltaY : e.deltaX), y: view.y - (e.shiftKey ? 0 : e.deltaY) } })
      }
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [])

  const toWorld = (e: { clientX: number; clientY: number }): Pt => {
    const r = ref.current!.getBoundingClientRect()
    const { view } = getState()
    return [(e.clientX - r.left - view.x) / view.zoom, (e.clientY - r.top - view.y) / view.zoom]
  }

  const selObjs = objects.filter((o) => selection.includes(o.id))
  const selBox = unionBox(selObjs.map(bbox))
  const style = () => getState().style

  function onPointerDown(e: React.PointerEvent) {
    if (e.button === 2) return
    const target = e.target as Element
    if (target.closest('textarea')) return
    // stop the browser's mousedown focus change, which would blur a text editor we mount below
    e.preventDefault()
    ;(document.activeElement as HTMLElement | null)?.blur?.()
    ref.current!.setPointerCapture(e.pointerId)
    const p = toWorld(e)
    const s = getState()
    if (s.editingId) setState({ editingId: null })

    if (e.button === 1 || tool === 'hand' || spaceDown) {
      setDrag({ kind: 'pan', sx: e.clientX, sy: e.clientY, vx: s.view.x, vy: s.view.y })
      return
    }

    if (tool === 'select') {
      const handle = target.getAttribute('data-handle')
      const movable = selObjs.filter((o) => !o.locked)
      const mBox = unionBox(movable.map(bbox))
      if (handle && mBox) {
        setDrag({ kind: 'resize', start: p, handle, box: mBox, orig: movable, moved: false })
        return
      }
      const id = target.closest('[data-id]')?.getAttribute('data-id')
      if (id) {
        const obj = s.doc.objects.find((o) => o.id === id)!
        let sel = s.selection
        if (e.shiftKey) sel = sel.includes(id) ? sel.filter((x) => x !== id) : [...sel, id]
        else if (!sel.includes(id)) sel = [id]
        setState({ selection: sel })
        if (obj.locked) return
        const orig = s.doc.objects.filter((o) => sel.includes(o.id) && !o.locked)
        setDrag({ kind: 'move', start: p, orig, moved: false, alt: e.altKey })
        return
      }
      if (!e.shiftKey) setState({ selection: [] })
      setDrag({ kind: 'marquee', start: p, add: e.shiftKey ? s.selection : [] })
      return
    }

    if (tool === 'eraser') {
      setDrag({ kind: 'erase', checked: false })
      eraseAt(e, { checked: false })
      return
    }

    const st = style()
    const base = { id: uid(), opacity: st.opacity }
    if (tool === 'text') {
      const o: TextObj = { ...base, type: 'text', x: p[0], y: p[1] - st.fontSize * 0.6, w: 260, h: st.fontSize * LINE_H, text: '', fontSize: st.fontSize, color: st.stroke }
      addObject(o)
      setState({ editingId: o.id, tool: 'select' })
      return
    }
    if (tool === 'sticky') {
      const o: StickyObj = { ...base, opacity: 1, type: 'sticky', x: p[0] - 100, y: p[1] - 100, w: 200, h: 200, text: '', fill: st.sticky, fontSize: 18 }
      addObject(o)
      setState({ editingId: o.id, tool: 'select' })
      return
    }
    if (tool === 'pen' || tool === 'highlighter') {
      const hl = tool === 'highlighter'
      setDraft({ ...base, type: 'path', points: [p], stroke: hl ? '#facc15' : st.stroke, strokeWidth: hl ? Math.max(12, st.strokeWidth * 4) : st.strokeWidth, highlighter: hl, opacity: hl ? 0.45 : st.opacity })
    } else if (tool === 'line' || tool === 'arrow') {
      setDraft({ ...base, type: tool, points: [p, p], stroke: st.stroke, strokeWidth: st.strokeWidth })
    } else if (tool === 'rect' || tool === 'ellipse') {
      setDraft({ ...base, type: tool, x: p[0], y: p[1], w: 0, h: 0, stroke: st.stroke, fill: st.fill, strokeWidth: st.strokeWidth })
    } else if (tool === 'redact') {
      setDraft({ ...base, opacity: 1, type: 'redact', x: p[0], y: p[1], w: 0, h: 0, fill: '#000000' })
    }
    setDrag({ kind: 'draw', start: p })
  }

  function eraseAt(e: { clientX: number; clientY: number }, d: { checked: boolean }) {
    const el = document.elementFromPoint(e.clientX, e.clientY)
    const id = el?.closest('[data-id]')?.getAttribute('data-id')
    const o = id && getState().doc.objects.find((x) => x.id === id)
    if (!o || o.locked) return
    // checkpoint lazily so a click that erases nothing leaves history alone
    if (!d.checked) { checkpoint(); d.checked = true }
    setDoc((doc) => ({ ...doc, objects: doc.objects.filter((x) => x.id !== id) }))
  }

  function onPointerMove(e: React.PointerEvent) {
    if (!drag) return
    const p = toWorld(e)
    if (drag.kind === 'pan') {
      setState((s) => ({ view: { ...s.view, x: drag.vx + e.clientX - drag.sx, y: drag.vy + e.clientY - drag.sy } }))
    } else if (drag.kind === 'erase') {
      eraseAt(e, drag)
    } else if (drag.kind === 'move') {
      const dx = p[0] - drag.start[0], dy = p[1] - drag.start[1]
      if (!drag.moved) {
        if (Math.hypot(dx, dy) * getState().view.zoom < 3) return
        checkpoint()
        if (drag.alt) {
          // alt-drag duplicates: originals stay, clones move
          const clones = drag.orig.map((o) => ({ ...o, id: uid() }))
          setDoc((d) => ({ ...d, objects: [...d.objects, ...clones] }))
          setState({ selection: clones.map((c) => c.id) })
          drag.orig = clones
        }
        drag.moved = true
      }
      const moved = new Map(drag.orig.map((o) => [o.id, moveObj(o, dx, dy)]))
      setDoc((d) => ({ ...d, objects: d.objects.map((o) => moved.get(o.id) ?? o) }))
    } else if (drag.kind === 'resize') {
      if (!drag.moved) { checkpoint(); drag.moved = true }
      const b = drag.box, h = drag.handle
      let x1 = b.x, y1 = b.y, x2 = b.x + b.w, y2 = b.y + b.h
      if (h.includes('w')) x1 = p[0]
      if (h.includes('e')) x2 = p[0]
      if (h.includes('n')) y1 = p[1]
      if (h.includes('s')) y2 = p[1]
      let to: Box = { x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.max(4, Math.abs(x2 - x1)), h: Math.max(4, Math.abs(y2 - y1)) }
      const keepRatio = e.shiftKey || drag.orig.some((o) => o.type === 'image')
      if (keepRatio && h.length === 2) {
        const k = Math.max(to.w / b.w, to.h / b.h)
        to = { w: b.w * k, h: b.h * k, x: h.includes('w') ? b.x + b.w - b.w * k : b.x, y: h.includes('n') ? b.y + b.h - b.h * k : b.y }
      }
      const resized = new Map(drag.orig.map((o) => [o.id, resizeObj(o, b, to)]))
      setDoc((d) => ({ ...d, objects: d.objects.map((o) => resized.get(o.id) ?? o) }))
    } else if (drag.kind === 'marquee') {
      const box = { x: Math.min(drag.start[0], p[0]), y: Math.min(drag.start[1], p[1]), w: Math.abs(p[0] - drag.start[0]), h: Math.abs(p[1] - drag.start[1]) }
      setMarquee(box)
      const ids = getState().doc.objects.filter((o) => intersects(box, bbox(o))).map((o) => o.id)
      setState({ selection: [...new Set([...drag.add, ...ids])] })
    } else if (drag.kind === 'draw' && draft) {
      const [sx, sy] = drag.start
      if (draft.type === 'path') {
        setDraft((d) => (d?.type === 'path' ? { ...d, points: [...d.points, p] } : d))
      } else if (draft.type === 'line' || draft.type === 'arrow') {
        let [ex, ey] = p
        if (e.shiftKey) {
          const a = Math.round(Math.atan2(ey - sy, ex - sx) / (Math.PI / 4)) * (Math.PI / 4)
          const len = Math.hypot(ex - sx, ey - sy)
          ex = sx + Math.cos(a) * len; ey = sy + Math.sin(a) * len
        }
        setDraft({ ...draft, points: [[sx, sy], [ex, ey]] })
      } else if ('w' in draft) {
        let w = p[0] - sx, hh = p[1] - sy
        if (e.shiftKey) { const m = Math.max(Math.abs(w), Math.abs(hh)); w = Math.sign(w || 1) * m; hh = Math.sign(hh || 1) * m }
        setDraft({ ...draft, x: Math.min(sx, sx + w), y: Math.min(sy, sy + hh), w: Math.abs(w), h: Math.abs(hh) })
      }
    }
  }

  function onPointerUp() {
    if (drag?.kind === 'draw' && draft) {
      let o = draft
      const b = bbox(o)
      const tiny = b.w < 3 && b.h < 3
      if (tiny && (o.type === 'rect' || o.type === 'ellipse' || o.type === 'redact')) o = { ...o, x: o.x - 60, y: o.y - 40, w: 120, h: 80 }
      if (tiny && (o.type === 'line' || o.type === 'arrow')) o = { ...o, points: [o.points[0], [o.points[0][0] + 120, o.points[0][1]]] }
      addObject(o, o.type !== 'path')
    }
    setDrag(null)
    setDraft(null)
    setMarquee(null)
  }

  function onDoubleClick(e: React.MouseEvent) {
    const id = (e.target as Element).closest('[data-id]')?.getAttribute('data-id')
    const o = id && getState().doc.objects.find((x) => x.id === id)
    if (o && (o.type === 'text' || o.type === 'sticky') && !o.locked) {
      setState({ editingId: o.id, selection: [o.id] })
    } else if (!o && tool === 'select') {
      // Miro habit: double-click empty space drops a sticky
      const p = toWorld(e)
      const st = getState().style
      const n: StickyObj = { id: uid(), opacity: 1, type: 'sticky', x: p[0] - 100, y: p[1] - 100, w: 200, h: 200, text: '', fill: st.sticky, fontSize: 18 }
      addObject(n)
      setState({ editingId: n.id })
    }
  }

  async function onDrop(e: React.DragEvent) {
    e.preventDefault()
    if (e.dataTransfer.files.length) await importFiles([...e.dataTransfer.files], toWorld(e))
  }

  const editing = objects.find((o) => o.id === editingId) as TextObj | StickyObj | undefined
  const cursor = drag?.kind === 'pan' ? 'grabbing' : tool === 'hand' || spaceDown ? 'grab' : tool === 'select' ? 'default' : tool === 'eraser' ? 'cell' : 'crosshair'
  const hz = 1 / view.zoom

  return (
    <div
      ref={ref}
      className="canvas-bg no-select absolute inset-0 overflow-hidden touch-none"
      style={{ cursor, backgroundSize: `${24 * view.zoom}px ${24 * view.zoom}px`, backgroundPosition: `${view.x}px ${view.y}px` }}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      onDoubleClick={onDoubleClick}
      onDragOver={(e) => e.preventDefault()}
      onDrop={onDrop}
      onContextMenu={(e) => e.preventDefault()}
    >
      <div className="absolute left-0 top-0 origin-top-left" style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.zoom})` }}>
        {pages.map((p) => (
          <PageView key={p.id} page={p} box={lay.get(p.id)!} zoom={view.zoom} active={p.id === activePage && pages.length > 1} />
        ))}
        <svg className="absolute left-0 top-0 overflow-visible" width={1} height={1}>
          {hits.map((h, i) => {
            const pb = lay.get(h.pageId)
            return pb && <rect key={i} x={pb.x + h.x} y={pb.y + h.y} width={h.w} height={h.h} fill="#facc15" opacity={0.45} pointerEvents="none" style={{ mixBlendMode: 'multiply' }} />
          })}
          {objects.map((o) => <ObjectView key={o.id} o={o} hideText={o.id === editingId} />)}
          {draft && <ObjectView o={draft} />}
          {selBox && !editingId && (
            <g pointerEvents="none">
              {selObjs.length > 1 && selObjs.map((o) => { const b = bbox(o); return <rect key={o.id} x={b.x} y={b.y} width={b.w} height={b.h} fill="none" stroke="var(--color-accent)" strokeWidth={hz} opacity={0.5} /> })}
              <rect x={selBox.x} y={selBox.y} width={selBox.w} height={selBox.h} fill="none" stroke="var(--color-accent)" strokeWidth={1.5 * hz} />
              {tool === 'select' && !selObjs.every((o) => o.locked) && HANDLES.map((h) => {
                const cx = selBox.x + (h.includes('w') ? 0 : h.includes('e') ? selBox.w : selBox.w / 2)
                const cy = selBox.y + (h.includes('n') ? 0 : h.includes('s') ? selBox.h : selBox.h / 2)
                const s = (h.length === 2 ? 9 : 7) * hz
                return <rect key={h} data-handle={h} x={cx - s / 2} y={cy - s / 2} width={s} height={s} rx={2 * hz} fill="white" stroke="var(--color-accent)" strokeWidth={1.5 * hz} pointerEvents="all" style={{ cursor: CURSORS[h] }} />
              })}
            </g>
          )}
          {marquee && <rect x={marquee.x} y={marquee.y} width={marquee.w} height={marquee.h} fill="var(--color-accent)" fillOpacity={0.08} stroke="var(--color-accent)" strokeWidth={hz} pointerEvents="none" />}
        </svg>
        {editing && <TextEditor key={editing.id} o={editing} />}
      </div>
      {pages.length === 0 && objects.length === 0 && (
        <div className="pointer-events-none absolute inset-0 grid place-items-center text-sm text-muted">Drop a PDF or image here, or start drawing</div>
      )}
    </div>
  )
}

function TextEditor({ o }: { o: TextObj | StickyObj }) {
  const ref = useRef<HTMLTextAreaElement>(null)
  const [text, setText] = useState(o.text)
  const [taH, setTaH] = useState(o.fontSize * LINE_H)
  const sticky = o.type === 'sticky'

  useEffect(() => {
    const el = ref.current!
    el.focus()
    el.setSelectionRange(el.value.length, el.value.length)
  }, [])
  useEffect(() => {
    const el = ref.current!
    el.style.height = '0px'
    el.style.height = el.scrollHeight + 'px'
    setTaH(el.scrollHeight)
  }, [text])

  function finish() {
    const el = ref.current
    const h = el ? el.scrollHeight : o.h
    if (!sticky && !text.trim()) {
      // a fresh empty text was already checkpointed by addObject; an emptied existing one needs its own step
      const drop = (d: DocState) => ({ ...d, objects: d.objects.filter((x) => x.id !== o.id) })
      if (o.text) commit(drop)
      else setDoc(drop)
    } else if (text !== o.text || (!sticky && Math.abs(h - o.h) > 1)) {
      commit((d) => ({
        ...d,
        objects: d.objects.map((x) => (x.id === o.id ? ({ ...x, text, ...(sticky ? { h: Math.max(o.h, h + STICKY_PAD * 2) } : { h }) } as Obj) : x)),
      }))
    }
    setState({ editingId: null })
  }

  const fs = o.fontSize
  const align = sticky ? 'center' : o.align ?? 'left'
  const pad = sticky ? STICKY_PAD : 0
  return (
    <textarea
      ref={ref}
      value={text}
      onChange={(e) => setText(e.target.value)}
      onBlur={finish}
      onKeyDown={(e) => {
        e.stopPropagation()
        if (e.key === 'Escape' || (e.key === 'Enter' && (e.metaKey || e.ctrlKey))) { e.preventDefault(); ref.current?.blur() }
      }}
      onPointerDown={(e) => e.stopPropagation()}
      placeholder={sticky ? 'Type something…' : 'Text'}
      spellCheck={false}
      className="absolute resize-none overflow-hidden border-0 bg-transparent p-0 outline-none placeholder:opacity-40"
      style={{
        left: o.x + pad,
        top: sticky ? o.y + Math.max(pad, (o.h - taH) / 2) : o.y,
        width: o.w - pad * 2,
        fontFamily: FONT,
        fontSize: fs,
        lineHeight: LINE_H,
        fontWeight: !sticky && o.bold ? 700 : 400,
        color: sticky ? '#1c1917' : (o as TextObj).color,
        textAlign: align,
        opacity: o.opacity,
        // SVG renders the first line at y + fontSize; textarea line box adds half-leading
        marginTop: -(fs * (LINE_H - 1)) / 2 + fs * 0.2,
        caretColor: 'var(--color-accent)',
      }}
    />
  )
}
