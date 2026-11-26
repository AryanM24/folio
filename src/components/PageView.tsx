import { memo, useEffect, useRef, useState } from 'react'
import type { Box, Page } from '../lib/types'
import { renderPage } from '../lib/pdf'

/** One PDF page, re-rendered at the current zoom only while it's on screen. */
export const PageView = memo(function PageView({ page, box, zoom, active }: { page: Page; box: Box; zoom: number; active: boolean }) {
  const ref = useRef<HTMLCanvasElement>(null)
  const [visible, setVisible] = useState(false)
  const [rendered, setRendered] = useState(0)

  useEffect(() => {
    const el = ref.current!
    // root must be the clipping viewport, or rootMargin is ignored
    const io = new IntersectionObserver(([e]) => setVisible(e.isIntersecting), { root: el.closest('.canvas-bg'), rootMargin: '600px' })
    io.observe(el)
    return () => io.disconnect()
  }, [])

  // free the backing store off-screen; long documents would otherwise hold GBs
  useEffect(() => {
    if (visible || !ref.current) return
    ref.current.width = ref.current.height = 0
    setRendered(0)
  }, [visible])

  useEffect(() => {
    if (!visible) return
    const dpr = window.devicePixelRatio || 1
    // cap the backing store so deep zoom doesn't allocate a 10k-px canvas
    const scale = Math.min(zoom * dpr, 5000 / Math.max(box.w, box.h))
    if (Math.abs(scale - rendered) / scale < 0.15) return
    const sig = { cancelled: false }
    const t = setTimeout(() => {
      const off = document.createElement('canvas')
      renderPage(page, off, scale, sig)
        .then(() => {
          if (sig.cancelled || !ref.current) return
          const c = ref.current
          c.width = off.width
          c.height = off.height
          c.getContext('2d')!.drawImage(off, 0, 0)
          setRendered(scale)
        })
        .catch(console.error)
    }, rendered ? 160 : 0)
    return () => { sig.cancelled = true; clearTimeout(t) }
  }, [visible, zoom, page, box.w, box.h, rendered])

  // page identity changed (rotation etc): force a fresh render
  useEffect(() => setRendered(0), [page])

  return (
    <canvas
      ref={ref}
      data-page={page.id}
      className={`absolute bg-white transition-shadow ${active ? 'shadow-[0_0_0_1px_var(--color-accent),0_8px_30px_rgba(0,0,0,.12)]' : 'shadow-[0_0_0_1px_rgba(0,0,0,.06),0_8px_30px_rgba(0,0,0,.08)]'}`}
      style={{ left: box.x, top: box.y, width: box.w, height: box.h }}
    />
  )
})
