// IndexedDB via idb-keyval: localStorage caps at ~5MB, too small for PDF bytes.
import { get, set, del, keys, delMany } from 'idb-keyval'
import type { DocMeta, DocState } from './types'

export const uid = () => crypto.randomUUID().slice(0, 12)

export async function listDocs(): Promise<DocMeta[]> {
  const ks = (await keys()).filter((k) => String(k).startsWith('meta:'))
  const metas = await Promise.all(ks.map((k) => get<DocMeta>(k)))
  return metas.filter(Boolean).sort((a, b) => b!.updatedAt - a!.updatedAt) as DocMeta[]
}

export const getMeta = (id: string) => get<DocMeta>(`meta:${id}`)
export const saveMeta = (m: DocMeta) => set(`meta:${m.id}`, m)
export const getState = (id: string) => get<DocState>(`state:${id}`)
export const saveState = (id: string, s: DocState) => set(`state:${id}`, s)
export const getSource = (srcId: string) => get<Uint8Array>(`src:${srcId}`)
export const saveSource = (srcId: string, bytes: Uint8Array) => set(`src:${srcId}`, bytes)

export async function deleteDoc(id: string) {
  const st = await getState(id)
  const srcs = new Set(st?.pages.map((p) => p.src).filter(Boolean) as string[])
  // duplicated docs share source bytes: keep any still referenced elsewhere
  for (const m of await listDocs()) {
    if (m.id === id) continue
    for (const p of (await getState(m.id))?.pages ?? []) if (p.src) srcs.delete(p.src)
  }
  await delMany([`meta:${id}`, `state:${id}`, ...[...srcs].map((s) => `src:${s}`)])
}

export const getSetting = <T,>(k: string) => get<T>(`setting:${k}`)
export const setSetting = (k: string, v: unknown) => (v == null ? del(`setting:${k}`) : set(`setting:${k}`, v))
