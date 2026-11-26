import { useEffect, useRef, useState } from 'react'
import { Button, Dropdown, Kbd, Label, Separator, Spinner, Tooltip, toast } from '@heroui/react'
import { ChevronLeft, Download, FileImage, Minus, PanelLeft, Plus, Redo2, Search, Undo2, X, ChevronUp, ChevronDown } from 'lucide-react'
import type { Obj } from '../lib/types'
import { getMeta, getSetting, getState as loadState, saveState, uid } from '../lib/storage'
import { touchMeta } from '../lib/docs'
import { thumbnail, searchText } from '../lib/pdf'
import { bbox, layout, moveObj, unionBox } from '../lib/geometry'
import { importFiles } from '../lib/files'
import {
  checkpoint, deleteSelection, getState, redo, reorder, resetEditor, revealBox, setDoc, setState, subscribe, undo, useStore, zoomAt, fitBox, viewCenterWorld, addObject, updateObjects,
} from '../store'
import { openDoc } from '../App'
import { Canvas } from './Canvas'
import { Toolbar, TOOLS, activateTool } from './Toolbar'
import { Inspector } from './Inspector'
import { PagesPanel } from './PagesPanel'
import { SignatureModal } from './SignatureModal'
import { ThemeToggle } from './ThemeToggle'
import { Logo } from './Library'

let clipboard: Obj[] = []
const CLIP_MARK = '\u2063folio-objects'

export function Editor({ docId }: { docId: string }) {
  const [loaded, setLoaded] = useState<'loading' | 'ok' | 'missing'>('loading')
  const [sigOpen, setSigOpen] = useState(false)
  const [pagesOpen, setPagesOpen] = useState(() => innerWidth > 900)
  const [saving, setSaving] = useState(false)

  // load
  useEffect(() => {
    let on = true
    ;(async () => {
      const [m, s, sig] = await Promise.all([getMeta(docId), loadState(docId), getSetting<string>('signature')])
      if (!on) return
      if (!m || !s) return setLoaded('missing')
      resetEditor(docId, m.name, s)
      setState({ signature: sig ?? null })
      setLoaded('ok')
      requestAnimationFrame(() => {
        const first = layout(s.pages).values().next().value
        const all = unionBox([...layout(s.pages).values()].concat(s.objects.map(bbox)))
        if (first) fitBox({ ...first, h: Math.min(first.h, innerHeight) }, 48, 1.25)
        else if (all) fitBox(all)
      })
    })()
    return () => { on = false }
  }, [docId])

  // autosave (debounced) + thumbnail refresh when page 1 changes
  useEffect(() => {
    if (loaded !== 'ok') return
    let t: ReturnType<typeof setTimeout>
    let prev = getState().doc
    let prevName = getState().name
    let dirty = false
    let pendingThumb = false
    const flush = async () => {
      clearTimeout(t)
      if (!dirty) return
      dirty = false
      const { doc, name } = getState()
      const wantThumb = pendingThumb
      pendingThumb = false
      try {
        await saveState(docId, doc)
        const thumb = wantThumb && doc.pages[0] ? await thumbnail(doc.pages[0]).catch(() => undefined) : undefined
        await touchMeta(docId, doc, { name, ...(thumb ? { thumb } : {}) })
      } catch (e) {
        toast.danger("Couldn't save to browser storage", { description: (e as Error).message })
      } finally {
        if (!dirty) setSaving(false)
      }
    }
    const un = subscribe(() => {
      const { doc, name } = getState()
      if (doc === prev && name === prevName) return
      if (doc.pages[0] !== prev.pages[0]) pendingThumb = true
      prev = doc; prevName = name
      dirty = true
      setSaving(true)
      clearTimeout(t)
      t = setTimeout(flush, 400)
    })
    const onHide = () => { if (document.visibilityState === 'hidden') flush() }
    addEventListener('pagehide', flush)
    document.addEventListener('visibilitychange', onHide)
    return () => { un(); removeEventListener('pagehide', flush); document.removeEventListener('visibilitychange', onHide); flush() }
  }, [docId, loaded])

  // keyboard shortcuts
  useEffect(() => {
    const keyMap = new Map(TOOLS.flat().map((t) => [t.key.toLowerCase(), t.id]))
    const isField = (t: EventTarget | null) => t instanceof HTMLElement && (t.isContentEditable || /INPUT|TEXTAREA|SELECT/.test(t.tagName))
    const down = (e: KeyboardEvent) => {
      if (isField(e.target)) return
      const s = getState()
      const mod = e.metaKey || e.ctrlKey
      const k = e.key.toLowerCase()
      if (k === ' ' && !s.spaceDown) { e.preventDefault(); setState({ spaceDown: true }); return }
      if (mod && k === 'z') { e.preventDefault(); e.shiftKey ? redo() : undo(); return }
      if (mod && k === 'y') { e.preventDefault(); redo(); return }
      if (mod && k === 'a') { e.preventDefault(); setState({ tool: 'select', selection: s.doc.objects.map((o) => o.id) }); return }
      if (mod && k === 'x' && s.selection.length) { setTimeout(deleteSelection); return }
      if (mod && k === 'd') { e.preventDefault(); paste(clipboardOf(s.selection), 16); return }
      if (mod && e.shiftKey && k === 'l') { e.preventDefault(); const sel = s.doc.objects.filter((o) => s.selection.includes(o.id)); const lock = !sel.every((o) => o.locked); updateObjects(s.selection, (o) => ({ ...o, locked: lock })); return }
      if (mod && (k === '=' || k === '+')) { e.preventDefault(); zoomAt(s.view.zoom * 1.25); return }
      if (mod && k === '-') { e.preventDefault(); zoomAt(s.view.zoom / 1.25); return }
      if (mod && k === '0') { e.preventDefault(); zoomAt(1); return }
      if (mod && k === '1' || (e.shiftKey && k === '1')) { e.preventDefault(); fitAll(); return }
      if (mod && k === 'f') { e.preventDefault(); document.getElementById('folio-search')?.focus(); return }
      if (mod && k === 's') { e.preventDefault(); exportPdf(); return }
      if (mod) return
      if (k === 'escape') { setState({ selection: [], editingId: null, tool: 'select', hits: [] }); return }
      if (k === 'backspace' || k === 'delete') { e.preventDefault(); deleteSelection(); return }
      if (k === ']') return reorder(e.altKey ? 'forward' : 'front')
      if (k === '[') return reorder(e.altKey ? 'backward' : 'back')
      if (k === 'enter' && s.selection.length === 1) {
        const o = s.doc.objects.find((x) => x.id === s.selection[0])
        if (o && (o.type === 'text' || o.type === 'sticky')) { e.preventDefault(); setState({ editingId: o.id }) }
        return
      }
      if (k.startsWith('arrow') && s.selection.length) {
        e.preventDefault()
        const d = e.shiftKey ? 10 : 1
        const [dx, dy] = k === 'arrowleft' ? [-d, 0] : k === 'arrowright' ? [d, 0] : k === 'arrowup' ? [0, -d] : [0, d]
        // repeated nudges merge into one undo step
        if (!e.repeat) checkpoint()
        setDoc((doc) => ({ ...doc, objects: doc.objects.map((o) => (s.selection.includes(o.id) && !o.locked ? moveObj(o, dx, dy) : o)) }))
        return
      }
      const tool = keyMap.get(k)
      if (tool && !e.repeat) activateTool(tool, () => setSigOpen(true))
    }
    const up = (e: KeyboardEvent) => { if (e.key === ' ') setState({ spaceDown: false }) }
    const blur = () => setState({ spaceDown: false })
    // copying objects writes a marker to the system clipboard so a later paste knows which wins
    const onCopy = (e: ClipboardEvent) => {
      const s = getState()
      if (isField(e.target) || !s.selection.length) return
      clipboard = s.doc.objects.filter((o) => s.selection.includes(o.id))
      e.clipboardData?.setData('text/plain', CLIP_MARK)
      e.preventDefault()
    }
    const onPaste = async (e: ClipboardEvent) => {
      if (isField(e.target)) return
      const files = [...(e.clipboardData?.files ?? [])]
      if (files.length) { e.preventDefault(); return importFiles(files) }
      const text = e.clipboardData?.getData('text/plain')
      if (text === CLIP_MARK) { e.preventDefault(); return paste(clipboard, 24) }
      if (text) {
        e.preventDefault()
        const [x, y] = viewCenterWorld()
        addObject({ id: uid(), type: 'text', opacity: 1, x: x - 150, y, w: 300, h: 24, text, fontSize: getState().style.fontSize, color: getState().style.stroke })
      }
    }
    addEventListener('keydown', down)
    addEventListener('keyup', up)
    addEventListener('paste', onPaste)
    addEventListener('copy', onCopy)
    addEventListener('cut', onCopy)
    addEventListener('blur', blur)
    return () => {
      removeEventListener('keydown', down); removeEventListener('keyup', up); removeEventListener('paste', onPaste)
      removeEventListener('copy', onCopy); removeEventListener('cut', onCopy); removeEventListener('blur', blur)
    }
  }, [])

  if (loaded === 'loading') return <div className="grid h-full place-items-center"><Spinner /></div>
  if (loaded === 'missing') {
    return (
      <div className="grid h-full place-items-center text-center">
        <div>
          <p className="font-medium">This document isn't in this browser.</p>
          <p className="mt-1 text-sm text-muted">Documents live in local storage, so links only work on the device that made them.</p>
          <Button className="mt-4" variant="secondary" onPress={() => openDoc(null)}>Back to library</Button>
        </div>
      </div>
    )
  }

  return (
    <div className="flex h-full flex-col bg-background">
      <TopBar saving={saving} pagesOpen={pagesOpen} togglePages={() => setPagesOpen((v) => !v)} />
      <div className="relative flex min-h-0 flex-1">
        {pagesOpen && <PagesPanel onExportPages={(ids) => exportPdf(ids)} />}
        <div className="relative min-w-0 flex-1">
          <Canvas />
          <div className="pointer-events-none absolute top-3 left-3 bottom-3 flex flex-col justify-center">
            <Toolbar openSignature={() => setSigOpen(true)} />
          </div>
          <div className="pointer-events-none absolute top-3 right-3"><Inspector /></div>
          <ZoomPill />
        </div>
      </div>
      <SignatureModal isOpen={sigOpen} onOpenChange={setSigOpen} />
    </div>
  )
}

function clipboardOf(ids: string[]) {
  return getState().doc.objects.filter((o) => ids.includes(o.id))
}
function paste(objs: Obj[], offset: number) {
  if (!objs.length) return
  const clones = objs.map((o) => ({ ...moveObj(o, offset, offset), id: uid(), locked: false }))
  checkpoint()
  setDoc((d) => ({ ...d, objects: [...d.objects, ...clones] }))
  setState({ selection: clones.map((c) => c.id), tool: 'select' })
  clipboard = clones
}
function fitAll() {
  const { doc } = getState()
  const b = unionBox([...layout(doc.pages).values()].concat(doc.objects.map(bbox)))
  if (b) fitBox(b, 64, 4)
}

async function exportPdf(pageIds?: string[]) {
  const s = getState()
  const id = toast('Preparing PDF…', { timeout: 0, indicator: <Spinner size="sm" color="current" /> })
  try {
    const { buildPdf, download } = await import('../lib/export')
    const bytes = await buildPdf(s.doc, pageIds)
    download(bytes, `${s.name || 'document'}${pageIds ? `-p${pageIds.map((p) => s.doc.pages.findIndex((x) => x.id === p) + 1).join('-')}` : ''}.pdf`)
    toast.close(id)
    toast.success('PDF exported')
  } catch (e) {
    toast.close(id)
    toast.danger('Export failed', { description: (e as Error).message })
  }
}

async function exportPng() {
  const s = getState()
  const p = s.doc.pages.find((x) => x.id === s.activePage) ?? s.doc.pages[0]
  if (!p) return
  const { pagePng, download } = await import('../lib/export')
  download(await pagePng(s.doc, p), `${s.name || 'page'}-p${s.doc.pages.indexOf(p) + 1}.png`)
}

function TopBar({ saving, pagesOpen, togglePages }: { saving: boolean; pagesOpen: boolean; togglePages: () => void }) {
  const name = useStore((s) => s.name)
  const canUndo = useStore((s) => s.past.length > 0)
  const canRedo = useStore((s) => s.future.length > 0)
  return (
    <header className="flex h-12 shrink-0 items-center gap-1 border-b border-border bg-surface px-2">
      <Tooltip delay={300} closeDelay={0}>
        <Button variant="ghost" size="sm" className="gap-1.5 px-2" aria-label="Back to library" onPress={() => openDoc(null)}>
          <ChevronLeft size={16} className="text-muted" /><Logo />
        </Button>
        <Tooltip.Content>All documents</Tooltip.Content>
      </Tooltip>
      <Tooltip delay={300} closeDelay={0}>
        <Button isIconOnly variant={pagesOpen ? 'secondary' : 'ghost'} size="sm" aria-label="Toggle pages panel" onPress={togglePages}><PanelLeft size={16} /></Button>
        <Tooltip.Content>Pages</Tooltip.Content>
      </Tooltip>
      <Separator orientation="vertical" className="mx-1 h-5" />
      <input
        value={name}
        onChange={(e) => setState({ name: e.target.value })}
        onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.blur()}
        aria-label="Document name"
        className="h-8 w-[min(18rem,30vw)] truncate rounded-md bg-transparent px-2 text-sm font-medium outline-none hover:bg-default focus:bg-default"
      />
      <span className="text-xs text-muted" aria-live="polite">{saving ? 'Saving…' : 'Saved locally'}</span>
      <div className="flex-1" />
      <SearchBox />
      <Separator orientation="vertical" className="mx-1 h-5" />
      <Tooltip delay={300} closeDelay={0}>
        <Button isIconOnly variant="ghost" size="sm" aria-label="Undo" isDisabled={!canUndo} onPress={undo}><Undo2 size={16} /></Button>
        <Tooltip.Content>Undo <span className="ml-1 text-muted">⌘Z</span></Tooltip.Content>
      </Tooltip>
      <Tooltip delay={300} closeDelay={0}>
        <Button isIconOnly variant="ghost" size="sm" aria-label="Redo" isDisabled={!canRedo} onPress={redo}><Redo2 size={16} /></Button>
        <Tooltip.Content>Redo <span className="ml-1 text-muted">⇧⌘Z</span></Tooltip.Content>
      </Tooltip>
      <ThemeToggle />
      <Dropdown>
        <Button size="sm" className="ml-1"><Download size={15} /> Export</Button>
        <Dropdown.Popover placement="bottom end">
          <Dropdown.Menu onAction={(k) => (k === 'pdf' ? exportPdf() : exportPng())}>
            <Dropdown.Item id="pdf" textValue="PDF"><Download size={14} /><Label>Download PDF</Label><Kbd slot="keyboard" variant="light"><Kbd.Abbr keyValue="command" /><Kbd.Content>S</Kbd.Content></Kbd></Dropdown.Item>
            <Dropdown.Item id="png" textValue="PNG"><FileImage size={14} /><Label>Current page as PNG</Label></Dropdown.Item>
          </Dropdown.Menu>
        </Dropdown.Popover>
      </Dropdown>
    </header>
  )
}

function SearchBox() {
  const [q, setQ] = useState('')
  const [idx, setIdx] = useState(0)
  const [busy, setBusy] = useState(false)
  const hits = useStore((s) => s.hits)
  const ref = useRef<HTMLInputElement>(null)

  async function run(query: string) {
    setBusy(true)
    const h = await searchText(getState().doc.pages, query)
    setBusy(false)
    setState({ hits: h })
    setIdx(0)
    if (h[0]) reveal(h[0])
    else if (query.trim()) toast('No matches', { timeout: 2000 })
  }
  function reveal(h: (typeof hits)[number]) {
    const pb = layout(getState().doc.pages).get(h.pageId)
    if (pb) revealBox({ x: pb.x + h.x, y: pb.y + h.y - 120, w: h.w, h: h.h })
  }
  function step(d: number) {
    if (!hits.length) return
    const i = (idx + d + hits.length) % hits.length
    setIdx(i)
    reveal(hits[i])
  }

  return (
    <div className="flex h-8 items-center gap-1 rounded-lg bg-default px-2 text-sm focus-within:ring-2 focus-within:ring-focus">
      {busy ? <Spinner size="sm" /> : <Search size={14} className="text-muted" />}
      <input
        id="folio-search"
        ref={ref}
        value={q}
        onChange={(e) => setQ(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') { e.preventDefault(); hits.length && q ? step(e.shiftKey ? -1 : 1) : run(q) }
          if (e.key === 'Escape') { setQ(''); setState({ hits: [] }); ref.current?.blur() }
        }}
        onBlur={() => q && !hits.length && run(q)}
        placeholder="Find in PDF"
        aria-label="Find in PDF"
        className="w-36 bg-transparent outline-none placeholder:text-muted"
      />
      {hits.length > 0 && (
        <>
          <span className="text-xs whitespace-nowrap text-muted tabular-nums">{idx + 1}/{hits.length}</span>
          <button className="rounded p-0.5 hover:bg-default-hover" aria-label="Previous match" onClick={() => step(-1)}><ChevronUp size={14} /></button>
          <button className="rounded p-0.5 hover:bg-default-hover" aria-label="Next match" onClick={() => step(1)}><ChevronDown size={14} /></button>
          <button className="rounded p-0.5 hover:bg-default-hover" aria-label="Clear search" onClick={() => { setQ(''); setState({ hits: [] }) }}><X size={14} /></button>
        </>
      )}
    </div>
  )
}

function ZoomPill() {
  const zoom = useStore((s) => s.view.zoom)
  return (
    <div className="absolute right-3 bottom-3 flex items-center gap-0.5 rounded-xl border border-border bg-overlay p-1 shadow-[var(--overlay-shadow)]" onPointerDown={(e) => e.stopPropagation()}>
      <Button isIconOnly size="sm" variant="ghost" aria-label="Zoom out" onPress={() => zoomAt(zoom / 1.25)}><Minus size={15} /></Button>
      <Dropdown>
        <Button size="sm" variant="ghost" className="w-14 px-0 tabular-nums">{Math.round(zoom * 100)}%</Button>
        <Dropdown.Popover placement="top end">
          <Dropdown.Menu onAction={(k) => (k === 'fit' ? fitAll() : k === 'page' ? fitPage() : zoomAt(Number(k)))}>
            <Dropdown.Item id="fit" textValue="Fit"><Label>Zoom to fit</Label><Kbd slot="keyboard" variant="light"><Kbd.Abbr keyValue="shift" /><Kbd.Content>1</Kbd.Content></Kbd></Dropdown.Item>
            <Dropdown.Item id="page" textValue="Fit page"><Label>Fit page</Label></Dropdown.Item>
            <Dropdown.Item id="0.5" textValue="50%"><Label>50%</Label></Dropdown.Item>
            <Dropdown.Item id="1" textValue="100%"><Label>100%</Label><Kbd slot="keyboard" variant="light"><Kbd.Abbr keyValue="command" /><Kbd.Content>0</Kbd.Content></Kbd></Dropdown.Item>
            <Dropdown.Item id="2" textValue="200%"><Label>200%</Label></Dropdown.Item>
          </Dropdown.Menu>
        </Dropdown.Popover>
      </Dropdown>
      <Button isIconOnly size="sm" variant="ghost" aria-label="Zoom in" onPress={() => zoomAt(zoom * 1.25)}><Plus size={15} /></Button>
    </div>
  )
}

function fitPage() {
  const s = getState()
  const b = layout(s.doc.pages).get(s.activePage ?? '')
  if (b) fitBox(b, 32, 4)
}

