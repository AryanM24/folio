import { BlendMode, degrees, PDFDocument, type PDFPage } from 'pdf-lib'
import { createElement } from 'react'
import { flushSync } from 'react-dom'
import { createRoot } from 'react-dom/client'
import type { Box, DocState, Obj, Page } from './types'
import { bbox, intersects, layout } from './geometry'
import { getSource } from './storage'
import { pageSize, renderPage } from './pdf'
import { ObjectView } from '../components/ObjectView'

const OVERLAY_SCALE = 3
const RASTER_SCALE = 2.5

// rendered via the client renderer to avoid shipping react-dom/server
function svgFor(objs: Obj[], box: Box, scale: number) {
  const host = document.createElement('div')
  const root = createRoot(host)
  flushSync(() => root.render(
    createElement(
      'svg',
      { xmlns: 'http://www.w3.org/2000/svg', width: box.w * scale, height: box.h * scale, viewBox: `${box.x} ${box.y} ${box.w} ${box.h}` },
      objs.map((o) => createElement(ObjectView, { key: o.id, o })),
    ),
  ))
  const svg = host.innerHTML
  root.unmount()
  return svg
}

async function drawSvg(ctx: CanvasRenderingContext2D, svg: string) {
  const url = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }))
  try {
    const img = new Image()
    img.src = url
    await img.decode()
    ctx.drawImage(img, 0, 0, ctx.canvas.width, ctx.canvas.height)
  } finally {
    URL.revokeObjectURL(url)
  }
}

/** Rasterise objects into a transparent canvas the size of `box`. */
async function overlay(objs: Obj[], box: Box, scale: number) {
  const c = document.createElement('canvas')
  c.width = Math.round(box.w * scale)
  c.height = Math.round(box.h * scale)
  await drawSvg(c.getContext('2d')!, svgFor(objs, box, scale))
  return c
}

/** Rotate a display-orientation canvas back into the page's native orientation. */
function toNative(src: HTMLCanvasElement, rot: number) {
  if (!rot) return src
  const c = document.createElement('canvas')
  const swap = rot % 180 !== 0
  c.width = swap ? src.height : src.width
  c.height = swap ? src.width : src.height
  const ctx = c.getContext('2d')!
  if (rot === 90) ctx.translate(0, c.height)
  if (rot === 180) ctx.translate(c.width, c.height)
  if (rot === 270) ctx.translate(c.width, 0)
  ctx.rotate((-rot * Math.PI) / 180)
  ctx.drawImage(src, 0, 0)
  return c
}

const canvasBytes = (c: HTMLCanvasElement, type = 'image/png', q?: number) =>
  new Promise<Uint8Array>((res, rej) => c.toBlob((b) => (b ? b.arrayBuffer().then((a) => res(new Uint8Array(a))) : rej(new Error('encode failed'))), type, q))

const isHl = (o: Obj) => o.type === 'path' && !!o.highlighter

async function stamp(out: PDFDocument, page: PDFPage, objs: Obj[], box: Box, rot: number) {
  const crop = page.getCropBox()
  for (const [layer, blend] of [[objs.filter(isHl), BlendMode.Multiply], [objs.filter((o) => !isHl(o)), BlendMode.Normal]] as const) {
    if (!layer.length) continue
    const png = await out.embedPng(await canvasBytes(toNative(await overlay(layer, box, OVERLAY_SCALE), rot)))
    page.drawImage(png, { x: crop.x, y: crop.y, width: crop.width, height: crop.height, blendMode: blend })
  }
}

export async function buildPdf(state: DocState, pageIds?: string[]): Promise<Uint8Array> {
  const out = await PDFDocument.create()
  const lay = layout(state.pages)
  const srcDocs = new Map<string, PDFDocument>()
  const pages = pageIds ? state.pages.filter((p) => pageIds.includes(p.id)) : state.pages

  for (const p of pages) {
    const box = lay.get(p.id)!
    const objs = state.objects.filter((o) => intersects(bbox(o), box))
    const { w, h } = pageSize(p)

    // Redaction must remove what's underneath, so the whole page becomes pixels.
    if (objs.some((o) => o.type === 'redact')) {
      const c = document.createElement('canvas')
      await renderPage(p, c, RASTER_SCALE)
      const ctx = c.getContext('2d')!
      ctx.globalCompositeOperation = 'multiply'
      ctx.drawImage(await overlay(objs.filter(isHl), box, RASTER_SCALE), 0, 0)
      ctx.globalCompositeOperation = 'source-over'
      ctx.drawImage(await overlay(objs.filter((o) => !isHl(o)), box, RASTER_SCALE), 0, 0)
      const img = await out.embedJpg(await canvasBytes(c, 'image/jpeg', 0.92))
      out.addPage([w, h]).drawImage(img, { x: 0, y: 0, width: w, height: h })
      continue
    }

    if (!p.src) {
      const page = out.addPage([w, h])
      if (objs.length) await stamp(out, page, objs, box, 0)
      continue
    }

    let src = srcDocs.get(p.src)
    if (!src) {
      const bytes = await getSource(p.src)
      if (!bytes) throw new Error('A source PDF is missing from storage')
      src = await PDFDocument.load(bytes, { ignoreEncryption: true })
      srcDocs.set(p.src, src)
    }
    const [page] = await out.copyPages(src, [p.index])
    out.addPage(page)
    const rot = (((page.getRotation().angle + p.rotation) % 360) + 360) % 360
    page.setRotation(degrees(rot))
    if (objs.length) await stamp(out, page, objs, box, rot)
  }
  return out.save()
}

/** One page (with its objects) as a PNG data blob. */
export async function pagePng(state: DocState, p: Page, scale = 2) {
  const box = layout(state.pages).get(p.id)!
  const c = document.createElement('canvas')
  await renderPage(p, c, scale)
  const objs = state.objects.filter((o) => intersects(bbox(o), box))
  c.getContext('2d')!.drawImage(await overlay(objs, box, scale), 0, 0)
  return new Blob([await canvasBytes(c) as BlobPart], { type: 'image/png' })
}

export function download(data: Uint8Array | Blob, name: string, type = 'application/pdf') {
  const blob = data instanceof Blob ? data : new Blob([data as BlobPart], { type })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = name
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 1000)
}

