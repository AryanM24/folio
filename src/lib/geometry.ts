import type { Box, Obj, Page, Pt } from './types'
import { pageSize } from './pdf'

export const PAGE_GAP = 48

/** Pages stack vertically, centred on x = 0. */
export function layout(pages: Page[]): Map<string, Box> {
  const m = new Map<string, Box>()
  let y = 0
  for (const p of pages) {
    const { w, h } = pageSize(p)
    m.set(p.id, { x: -w / 2, y, w, h })
    y += h + PAGE_GAP
  }
  return m
}

export function bbox(o: Obj): Box {
  if ('points' in o) {
    let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity
    for (const [x, y] of o.points) {
      x1 = Math.min(x1, x); y1 = Math.min(y1, y); x2 = Math.max(x2, x); y2 = Math.max(y2, y)
    }
    const pad = o.strokeWidth / 2
    return { x: x1 - pad, y: y1 - pad, w: x2 - x1 + pad * 2, h: y2 - y1 + pad * 2 }
  }
  return { x: o.x, y: o.y, w: o.w, h: o.h }
}

export function unionBox(boxes: Box[]): Box | null {
  if (!boxes.length) return null
  let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity
  for (const b of boxes) {
    x1 = Math.min(x1, b.x); y1 = Math.min(y1, b.y); x2 = Math.max(x2, b.x + b.w); y2 = Math.max(y2, b.y + b.h)
  }
  return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 }
}

export const intersects = (a: Box, b: Box) => a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
export const contains = (b: Box, [x, y]: Pt) => x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h

export function moveObj<T extends Obj>(o: T, dx: number, dy: number): T {
  if ('points' in o) return { ...o, points: o.points.map(([x, y]) => [x + dx, y + dy]) }
  return { ...o, x: o.x + dx, y: o.y + dy }
}

/** Map an object from one bounding box onto another (resize). */
export function resizeObj<T extends Obj>(o: T, from: Box, to: Box): T {
  const sx = from.w ? to.w / from.w : 1
  const sy = from.h ? to.h / from.h : 1
  const map = ([x, y]: Pt): Pt => [to.x + (x - from.x) * sx, to.y + (y - from.y) * sy]
  if ('points' in o) return { ...o, points: o.points.map(map) }
  const [x, y] = map([o.x, o.y])
  return { ...o, x, y, w: Math.max(4, o.w * sx), h: Math.max(4, o.h * sy) }
}

/** Which page (if any) contains the point. */
export function pageAt(lay: Map<string, Box>, pt: Pt): string | null {
  for (const [id, b] of lay) if (contains(b, pt)) return id
  return null
}

/**
 * After the page list changes (reorder/rotate/delete/insert), carry each object
 * along with the page it sat on. Objects on deleted pages are dropped.
 */
export function relayoutObjects(oldPages: Page[], newPages: Page[], objects: Obj[]): Obj[] {
  const a = layout(oldPages), b = layout(newPages)
  const out: Obj[] = []
  for (const o of objects) {
    const bb = bbox(o)
    const pid = pageAt(a, [bb.x + bb.w / 2, bb.y + bb.h / 2])
    if (!pid) { out.push(o); continue }
    const nb = b.get(pid)
    if (!nb) continue
    const ob = a.get(pid)!
    out.push(moveObj(o, nb.x - ob.x, nb.y - ob.y))
  }
  return out
}

// ---- text measuring (shared by screen and export so wrapping matches) ----
export const FONT = 'Helvetica, Arial, sans-serif'
let mctx: CanvasRenderingContext2D | null = null
export function wrapText(text: string, fontSize: number, maxW: number, bold = false): string[] {
  mctx ??= document.createElement('canvas').getContext('2d')!
  mctx.font = `${bold ? 'bold ' : ''}${fontSize}px ${FONT}`
  const lines: string[] = []
  for (const para of text.split('\n')) {
    let line = ''
    for (const word of para.split(/(\s+)/)) {
      const next = line + word
      if (line && mctx.measureText(next).width > maxW && word.trim()) {
        lines.push(line.trimEnd())
        line = word.trimStart()
      } else line = next
    }
    lines.push(line)
  }
  return lines
}
export const LINE_H = 1.3
