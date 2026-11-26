import type { ImageObj, Pt } from './types'
import { importPdf } from './pdf'
import { saveSource, uid } from './storage'
import { addObject, setPages, viewCenterWorld } from '../store'

export const readDataUrl = (f: Blob) =>
  new Promise<string>((res, rej) => {
    const r = new FileReader()
    r.onload = () => res(r.result as string)
    r.onerror = rej
    r.readAsDataURL(f)
  })

export const imageSize = (src: string) =>
  new Promise<{ w: number; h: number }>((res, rej) => {
    const i = new Image()
    i.onload = () => res({ w: i.naturalWidth, h: i.naturalHeight })
    i.onerror = rej
    i.src = src
  })

/** Place an image object centred at `at` (world coords), max 360pt wide. */
export async function placeImage(src: string, at: Pt = viewCenterWorld(), maxW = 360) {
  const { w, h } = await imageSize(src)
  const k = Math.min(1, maxW / w)
  const o: ImageObj = { id: uid(), type: 'image', opacity: 1, src, x: at[0] - (w * k) / 2, y: at[1] - (h * k) / 2, w: w * k, h: h * k }
  addObject(o)
}

/** PDFs are appended as pages (merge); images become objects. */
export async function importFiles(files: File[], at?: Pt) {
  for (const f of files) {
    if (f.type === 'application/pdf' || f.name.toLowerCase().endsWith('.pdf')) {
      const bytes = new Uint8Array(await f.arrayBuffer())
      const { srcId, pages } = await importPdf(bytes)
      await saveSource(srcId, bytes)
      setPages((ps) => [...ps, ...pages])
    } else if (f.type.startsWith('image/')) {
      await placeImage(await readDataUrl(f), at)
    }
  }
}

export function pickFiles(accept: string, multiple = true) {
  return new Promise<File[]>((res) => {
    const i = document.createElement('input')
    i.type = 'file'
    i.accept = accept
    i.multiple = multiple
    i.onchange = () => res([...(i.files ?? [])])
    i.click()
  })
}
