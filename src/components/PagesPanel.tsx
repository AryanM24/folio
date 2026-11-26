import { memo, useEffect, useMemo, useState } from 'react'
import { Button, Dropdown, Label, ScrollShadow, Tooltip } from '@heroui/react'
import { Copy, FilePlus, FileUp, MoreHorizontal, RotateCw, Trash2, Download } from 'lucide-react'
import type { Page } from '../lib/types'
import { thumbnail } from '../lib/pdf'
import { layout } from '../lib/geometry'
import { uid } from '../lib/storage'
import { blankPage } from '../lib/docs'
import { importFiles, pickFiles } from '../lib/files'
import { getState, revealBox, setPages, setState, useStore } from '../store'

const thumbs = new Map<string, Promise<string>>()
const thumbFor = (p: Page) => {
  const k = `${p.src}:${p.index}:${p.rotation}:${p.w}`
  if (!thumbs.has(k)) thumbs.set(k, thumbnail(p, 160))
  return thumbs.get(k)!
}

const Thumb = memo(function Thumb({ page }: { page: Page }) {
  const [src, setSrc] = useState<string>()
  useEffect(() => { let on = true; thumbFor(page).then((s) => on && setSrc(s)); return () => { on = false } }, [page])
  return src ? <img src={src} alt="" draggable={false} className="block h-auto w-full" /> : <div className="aspect-[3/4] w-full bg-white" />
})

export function PagesPanel({ onExportPages }: { onExportPages: (ids: string[]) => void }) {
  const pages = useStore((s) => s.doc.pages)
  const active = useStore((s) => s.activePage)
  const lay = useMemo(() => layout(pages), [pages])
  const [dragId, setDragId] = useState<string | null>(null)
  const [overIdx, setOverIdx] = useState<number | null>(null)

  const go = (id: string) => { const b = lay.get(id); if (b) revealBox(b); setState({ activePage: id }) }
  const rotate = (id: string) => setPages((ps) => ps.map((p) => (p.id === id ? { ...p, rotation: (p.rotation + 90) % 360 } : p)))
  const dup = (id: string) => setPages((ps) => ps.flatMap((p) => (p.id === id ? [p, { ...p, id: uid() }] : [p])))
  const del = (id: string) => setPages((ps) => ps.filter((p) => p.id !== id))
  const insertBlank = () => {
    const at = pages.findIndex((p) => p.id === getState().activePage)
    const np = { ...blankPage(), ...(pages[at] ? { w: pages[at].w, h: pages[at].h } : {}) }
    setPages((ps) => [...ps.slice(0, at + 1), np, ...ps.slice(at + 1)])
  }

  function drop(to: number) {
    if (!dragId) return
    setPages((ps) => {
      const from = ps.findIndex((p) => p.id === dragId)
      const next = ps.filter((p) => p.id !== dragId)
      next.splice(to > from ? to - 1 : to, 0, ps[from])
      return next
    })
    setDragId(null)
    setOverIdx(null)
  }

  return (
    <aside className="flex w-48 shrink-0 flex-col border-r border-border bg-surface" onPointerDown={(e) => e.stopPropagation()}>
      <div className="flex h-10 items-center justify-between pr-2 pl-4">
        <span className="text-xs font-medium">Pages <span className="text-muted tabular-nums">{pages.length}</span></span>
        <div className="flex">
          <Tooltip delay={300} closeDelay={0}>
            <Button isIconOnly size="sm" variant="ghost" aria-label="Insert blank page" onPress={insertBlank}><FilePlus size={15} /></Button>
            <Tooltip.Content>Insert blank page</Tooltip.Content>
          </Tooltip>
          <Tooltip delay={300} closeDelay={0}>
            <Button isIconOnly size="sm" variant="ghost" aria-label="Merge PDF" onPress={async () => importFiles(await pickFiles('application/pdf'))}><FileUp size={15} /></Button>
            <Tooltip.Content>Append pages from PDF</Tooltip.Content>
          </Tooltip>
        </div>
      </div>
      <ScrollShadow className="flex-1 overflow-y-auto px-4 pb-6" onDragOver={(e) => e.preventDefault()}>
        {pages.map((p, i) => (
          <div
            key={p.id}
            draggable
            onDragStart={(e) => { setDragId(p.id); e.dataTransfer.effectAllowed = 'move' }}
            onDragEnd={() => { setDragId(null); setOverIdx(null) }}
            onDragOver={(e) => { if (!dragId) return; e.preventDefault(); const r = e.currentTarget.getBoundingClientRect(); setOverIdx(e.clientY < r.top + r.height / 2 ? i : i + 1) }}
            onDrop={(e) => { e.preventDefault(); e.stopPropagation(); if (overIdx != null) drop(overIdx) }}
            className={`group relative py-2 ${dragId === p.id ? 'opacity-40' : ''}`}
          >
            {overIdx === i && <div className="absolute -top-px right-0 left-0 h-0.5 rounded bg-accent" />}
            {overIdx === i + 1 && i === pages.length - 1 && <div className="absolute right-0 -bottom-px left-0 h-0.5 rounded bg-accent" />}
            <button
              onClick={() => go(p.id)}
              className={`block w-full overflow-hidden rounded-md bg-white transition-shadow ${p.id === active ? 'shadow-[0_0_0_2px_var(--color-accent)]' : 'shadow-[0_0_0_1px_var(--color-border)] hover:shadow-[0_0_0_1px_var(--color-field-border-hover)]'}`}
              aria-label={`Page ${i + 1}`}
            >
              <Thumb page={p} />
            </button>
            <div className="mt-1.5 flex items-center justify-between">
              <span className={`text-xs tabular-nums ${p.id === active ? 'font-medium' : 'text-muted'}`}>{i + 1}</span>
              <div className="flex opacity-0 transition-opacity group-hover:opacity-100 has-[[aria-expanded=true]]:opacity-100">
                <Button isIconOnly size="sm" variant="ghost" className="size-6 min-w-6" aria-label="Rotate page" onPress={() => rotate(p.id)}><RotateCw size={13} /></Button>
                <Dropdown>
                  <Button isIconOnly size="sm" variant="ghost" className="size-6 min-w-6" aria-label="Page actions"><MoreHorizontal size={13} /></Button>
                  <Dropdown.Popover>
                    <Dropdown.Menu onAction={(k) => (k === 'dup' ? dup(p.id) : k === 'del' ? del(p.id) : k === 'rot' ? rotate(p.id) : onExportPages([p.id]))}>
                      <Dropdown.Item id="rot" textValue="Rotate"><RotateCw size={14} /><Label>Rotate 90°</Label></Dropdown.Item>
                      <Dropdown.Item id="dup" textValue="Duplicate"><Copy size={14} /><Label>Duplicate</Label></Dropdown.Item>
                      <Dropdown.Item id="exp" textValue="Extract"><Download size={14} /><Label>Extract as PDF</Label></Dropdown.Item>
                      <Dropdown.Item id="del" textValue="Delete" variant="danger" isDisabled={pages.length <= 1}><Trash2 size={14} /><Label>Delete page</Label></Dropdown.Item>
                    </Dropdown.Menu>
                  </Dropdown.Popover>
                </Dropdown>
              </div>
            </div>
          </div>
        ))}
      </ScrollShadow>
    </aside>
  )
}
