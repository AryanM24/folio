import * as pdfjs from 'pdfjs-dist'
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import type { Page } from './types'
import { getSource, uid } from './storage'

pdfjs.GlobalWorkerOptions.workerSrc = workerUrl

const cache = new Map<string, Promise<PDFDocumentProxy>>()

export function loadPdf(srcId: string, bytes?: Uint8Array) {
  let p = cache.get(srcId)
  if (!p) {
    p = (async () => {
      const b = bytes ?? (await getSource(srcId))
      if (!b) throw new Error('Missing PDF source')
      // pdf.js transfers the buffer to its worker, so hand it a copy
      return pdfjs.getDocument({ data: b.slice() }).promise
    })()
    cache.set(srcId, p)
    p.catch(() => cache.delete(srcId)) // let a transient failure retry
  }
  return p
}

/** Parse a PDF file into pages. */
export async function importPdf(bytes: Uint8Array): Promise<{ srcId: string; pages: Page[] }> {
  const srcId = uid()
  const doc = await loadPdf(srcId, bytes)
  const pages: Page[] = []
  for (let i = 0; i < doc.numPages; i++) {
    const pg = await doc.getPage(i + 1)
    // w/h include the file's own /Rotate; user rotation is layered on top
    const vp = pg.getViewport({ scale: 1 })
    pages.push({ id: uid(), src: srcId, index: i, w: vp.width, h: vp.height, rotation: 0 })
  }
  return { srcId, pages }
}

export const pageSize = (p: Page) => (p.rotation % 180 === 0 ? { w: p.w, h: p.h } : { w: p.h, h: p.w })

/** Render a page to a canvas at `scale` css-px per point. */
export async function renderPage(p: Page, canvas: HTMLCanvasElement, scale: number, signal?: { cancelled: boolean }) {
  const { w, h } = pageSize(p)
  canvas.width = Math.max(1, Math.round(w * scale))
  canvas.height = Math.max(1, Math.round(h * scale))
  const ctx = canvas.getContext('2d')!
  ctx.fillStyle = '#fff'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  if (!p.src) return
  const doc = await loadPdf(p.src)
  if (signal?.cancelled) return
  const pg = await doc.getPage(p.index + 1)
  const vp = pg.getViewport({ scale, rotation: (pg.rotate + p.rotation) % 360 })
  const task = pg.render({ canvas, viewport: vp, background: '#ffffff' })
  try {
    await task.promise
  } catch (e) {
    if ((e as Error)?.name !== 'RenderingCancelledException') throw e
  }
}

export async function thumbnail(p: Page, width = 240) {
  const c = document.createElement('canvas')
  await renderPage(p, c, width / pageSize(p).w)
  return c.toDataURL('image/jpeg', 0.7)
}

export interface TextHit { pageId: string; x: number; y: number; w: number; h: number }

/** Find text matches; returns boxes in page-local points (top-left origin). */
export async function searchText(pages: Page[], query: string): Promise<TextHit[]> {
  const q = query.trim().toLowerCase()
  if (!q) return []
  const out: TextHit[] = []
  for (const p of pages) {
    if (!p.src) continue
    const doc = await loadPdf(p.src)
    const pg = await doc.getPage(p.index + 1)
    const vp = pg.getViewport({ scale: 1, rotation: (pg.rotate + p.rotation) % 360 })
    const tc = await pg.getTextContent()
    for (const it of tc.items) {
      if (!('str' in it) || !it.str) continue
      const s = it.str.toLowerCase()
      let at = s.indexOf(q)
      while (at !== -1) {
        const [, , c, d, e, f] = it.transform as number[]
        const fontH = Math.hypot(c, d) || 10
        // shortcut: assumes horizontal text with even glyph widths; good enough for highlighting
        const charW = it.width / Math.max(1, it.str.length)
        const [x1, y1] = vp.convertToViewportPoint(e + at * charW, f - fontH * 0.2)
        const [x2, y2] = vp.convertToViewportPoint(e + (at + q.length) * charW, f + fontH * 0.85)
        out.push({ pageId: p.id, x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.abs(x2 - x1) || 4, h: Math.abs(y2 - y1) || fontH })
        at = s.indexOf(q, at + q.length)
      }
    }
  }
  return out
}
