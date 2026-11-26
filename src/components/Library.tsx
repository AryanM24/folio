import { useEffect, useState } from 'react'
import { Button, Dropdown, Label, SearchField, Spinner, toast } from '@heroui/react'
import { Copy, FilePlus2, FileUp, HardDrive, MoreHorizontal, Trash2 } from 'lucide-react'
import type { DocMeta } from '../lib/types'
import { listDocs } from '../lib/storage'
import { createBlank, createFromFile, deleteDoc, duplicateDoc } from '../lib/docs'
import { pickFiles } from '../lib/files'
import { openDoc } from '../App'
import { ThemeToggle } from './ThemeToggle'

const ago = (t: number) => {
  const s = (Date.now() - t) / 1000
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

export function Library() {
  const [docs, setDocs] = useState<DocMeta[] | null>(null)
  const [q, setQ] = useState('')
  const [busy, setBusy] = useState(false)
  const [over, setOver] = useState(false)
  const refresh = () => listDocs().then(setDocs)
  useEffect(() => { refresh() }, [])

  async function importPdfs(files: File[]) {
    const pdfs = files.filter((f) => f.type === 'application/pdf' || f.name.toLowerCase().endsWith('.pdf'))
    if (!pdfs.length) return
    setBusy(true)
    try {
      let last = ''
      for (const f of pdfs) last = await createFromFile(f)
      if (pdfs.length === 1) openDoc(last)
      else refresh()
    } catch (e) {
      toast.danger("Couldn't open that PDF", { description: (e as Error).message })
    } finally {
      setBusy(false)
    }
  }

  const shown = docs?.filter((d) => d.name.toLowerCase().includes(q.toLowerCase()))

  return (
    <div
      className="min-h-full bg-background"
      onDragOver={(e) => { e.preventDefault(); setOver(true) }}
      onDragLeave={(e) => { if (e.currentTarget === e.target) setOver(false) }}
      onDrop={(e) => { e.preventDefault(); setOver(false); importPdfs([...e.dataTransfer.files]) }}
    >
      <header className="mx-auto flex h-14 max-w-6xl items-center gap-3 px-6">
        <Logo />
        <span className="text-sm font-semibold tracking-tight">Folio</span>
        <div className="flex-1" />
        <ThemeToggle />
      </header>

      <main className="mx-auto max-w-6xl px-6 pb-24">
        <section className="flex flex-col gap-6 pt-10 pb-8 md:flex-row md:items-end md:justify-between">
          <div className="max-w-xl">
            <h1 className="text-3xl font-semibold tracking-tight text-balance">Edit PDFs on an infinite canvas</h1>
            <p className="mt-2 text-sm text-muted text-pretty">
              Annotate, sign, redact, rearrange and merge pages, with sticky notes and shapes around them. Everything stays in this browser.
            </p>
          </div>
          <div className="flex gap-2">
            <Button variant="secondary" onPress={async () => openDoc(await createBlank())}>
              <FilePlus2 size={16} /> New board
            </Button>
            <Button isPending={busy} onPress={async () => importPdfs(await pickFiles('application/pdf'))}>
              {busy ? <Spinner color="current" size="sm" /> : <FileUp size={16} />} Open PDF
            </Button>
          </div>
        </section>

        <div className="mb-4 flex items-center justify-between gap-4">
          <h2 className="text-sm font-medium">Recent</h2>
          {!!docs?.length && (
            <SearchField aria-label="Search documents" value={q} onChange={setQ}>
              <SearchField.Group>
                <SearchField.SearchIcon />
                <SearchField.Input className="w-56" placeholder="Search" />
                <SearchField.ClearButton />
              </SearchField.Group>
            </SearchField>
          )}
        </div>

        {docs === null ? (
          <div className="grid h-40 place-items-center"><Spinner /></div>
        ) : docs.length === 0 ? (
          <button
            onClick={async () => importPdfs(await pickFiles('application/pdf'))}
            className={`flex h-64 w-full flex-col items-center justify-center gap-3 rounded-2xl border border-dashed text-sm transition-colors ${over ? 'border-accent bg-accent-soft' : 'border-border hover:bg-surface-secondary'}`}
          >
            <FileUp size={22} className="text-muted" />
            <span className="font-medium">Drop a PDF here</span>
            <span className="text-muted">or click to choose a file</span>
          </button>
        ) : (
          <div className={`grid grid-cols-2 gap-x-5 gap-y-7 rounded-2xl transition-colors sm:grid-cols-3 lg:grid-cols-5 ${over ? 'bg-accent-soft outline-2 outline-dashed outline-accent outline-offset-8' : ''}`}>
            {shown!.map((d) => (
              <div key={d.id} className="group relative">
                <button onClick={() => openDoc(d.id)} className="block w-full text-left">
                  <div className="aspect-[3/4] overflow-hidden rounded-xl bg-surface-secondary shadow-[0_0_0_1px_var(--color-border)] transition-shadow group-hover:shadow-[0_0_0_1px_var(--color-border),0_10px_30px_-10px_rgba(0,0,0,.25)]">
                    {d.thumb ? <img src={d.thumb} alt="" className="h-full w-full object-cover object-top" /> : <div className="canvas-bg h-full w-full" style={{ backgroundSize: '16px 16px' }} />}
                  </div>
                  <div className="mt-2.5 truncate text-sm font-medium">{d.name}</div>
                  <div className="text-xs text-muted tabular-nums">{d.pageCount} {d.pageCount === 1 ? 'page' : 'pages'} · {ago(d.updatedAt)}</div>
                </button>
                <div className="absolute top-2 right-2 opacity-0 transition-opacity group-hover:opacity-100 has-[[aria-expanded=true]]:opacity-100">
                  <Dropdown>
                    <Button isIconOnly size="sm" variant="secondary" aria-label="Document actions"><MoreHorizontal size={16} /></Button>
                    <Dropdown.Popover>
                      <Dropdown.Menu
                        onAction={async (k) => {
                          if (k === 'dup') await duplicateDoc(d.id)
                          if (k === 'del') { await deleteDoc(d.id); toast(`Deleted “${d.name}”`) }
                          refresh()
                        }}
                      >
                        <Dropdown.Item id="dup" textValue="Duplicate"><Copy size={14} /><Label>Duplicate</Label></Dropdown.Item>
                        <Dropdown.Item id="del" textValue="Delete" variant="danger"><Trash2 size={14} /><Label>Delete</Label></Dropdown.Item>
                      </Dropdown.Menu>
                    </Dropdown.Popover>
                  </Dropdown>
                </div>
              </div>
            ))}
          </div>
        )}

        <p className="mt-16 flex items-center gap-2 text-xs text-muted">
          <HardDrive size={13} /> Files are stored in this browser's IndexedDB. Nothing is uploaded.
        </p>
      </main>
    </div>
  )
}

export function Logo() {
  return (
    <svg width="22" height="22" viewBox="0 0 32 32" aria-hidden>
      <rect width="32" height="32" rx="8" className="fill-foreground" />
      <path d="M10 8h9l5 5v11H10z" className="fill-background" />
      <path d="M19 8v5h5" className="fill-foreground opacity-30" />
    </svg>
  )
}
