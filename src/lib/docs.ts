import type { DocMeta, DocState, Page } from './types'
import { importPdf, thumbnail } from './pdf'
import { deleteDoc, getMeta, getState, saveMeta, saveSource, saveState, uid } from './storage'

const LETTER = { w: 612, h: 792 }

export async function createDoc(name: string, pages: Page[]): Promise<string> {
  const id = uid()
  const now = Date.now()
  const thumb = pages[0] ? await thumbnail(pages[0]).catch(() => undefined) : undefined
  await saveState(id, { pages, objects: [] })
  await saveMeta({ id, name, createdAt: now, updatedAt: now, pageCount: pages.length, thumb })
  return id
}

export async function createFromFile(f: File) {
  const bytes = new Uint8Array(await f.arrayBuffer())
  const { srcId, pages } = await importPdf(bytes)
  await saveSource(srcId, bytes)
  return createDoc(f.name.replace(/\.pdf$/i, ''), pages)
}

export const blankPage = (): Page => ({ id: uid(), src: null, index: 0, ...LETTER, rotation: 0 })

export const createBlank = (name = 'Untitled board') => createDoc(name, [blankPage()])

export async function duplicateDoc(id: string) {
  const [m, s] = await Promise.all([getMeta(id), getState(id)])
  if (!m || !s) return
  const nid = uid()
  // source bytes are shared by id; deleteDoc keeps them while any doc references them
  const now = Date.now()
  await saveState(nid, structuredClone(s))
  await saveMeta({ ...m, id: nid, name: `${m.name} copy`, createdAt: now, updatedAt: now })
  return nid
}

export async function touchMeta(id: string, state: DocState, patch: Partial<DocMeta> = {}) {
  const m = await getMeta(id)
  if (!m) return
  await saveMeta({ ...m, ...patch, pageCount: state.pages.length, updatedAt: Date.now() })
}

export { deleteDoc }
