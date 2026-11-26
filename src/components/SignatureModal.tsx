import { useEffect, useRef, useState } from 'react'
import { Button, Modal } from '@heroui/react'
import { Signature } from 'lucide-react'
import { setSetting } from '../lib/storage'
import { setState, viewCenterWorld } from '../store'
import { placeImage } from '../lib/files'

/** Draw a signature once; it's saved locally and reused by the Signature tool. */
export function SignatureModal({ isOpen, onOpenChange }: { isOpen: boolean; onOpenChange: (v: boolean) => void }) {
  const ref = useRef<HTMLCanvasElement>(null)
  const [empty, setEmpty] = useState(true)
  const last = useRef<[number, number] | null>(null)

  useEffect(() => {
    if (!isOpen) return
    // the canvas mounts with the modal; wait a frame for layout
    const id = requestAnimationFrame(() => {
      const c = ref.current
      if (!c) return
      const r = c.getBoundingClientRect()
      c.width = r.width * 2
      c.height = r.height * 2
      setEmpty(true)
    })
    return () => cancelAnimationFrame(id)
  }, [isOpen])

  const pt = (e: React.PointerEvent): [number, number] => {
    const r = ref.current!.getBoundingClientRect()
    return [(e.clientX - r.left) * 2, (e.clientY - r.top) * 2]
  }
  function line(to: [number, number]) {
    const ctx = ref.current!.getContext('2d')!
    ctx.strokeStyle = '#111827'
    ctx.lineWidth = 5
    ctx.lineCap = ctx.lineJoin = 'round'
    ctx.beginPath()
    ctx.moveTo(...(last.current ?? to))
    ctx.lineTo(...to)
    ctx.stroke()
    last.current = to
  }

  function trimmed() {
    const c = ref.current!
    const { data, width, height } = c.getContext('2d')!.getImageData(0, 0, c.width, c.height)
    let x1 = width, y1 = height, x2 = 0, y2 = 0
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      if (data[(y * width + x) * 4 + 3]) { x1 = Math.min(x1, x); y1 = Math.min(y1, y); x2 = Math.max(x2, x); y2 = Math.max(y2, y) }
    }
    const out = document.createElement('canvas')
    out.width = x2 - x1 + 8
    out.height = y2 - y1 + 8
    out.getContext('2d')!.drawImage(c, x1 - 4, y1 - 4, out.width, out.height, 0, 0, out.width, out.height)
    return out.toDataURL('image/png')
  }

  async function save(close: () => void) {
    const sig = trimmed()
    setState({ signature: sig })
    await setSetting('signature', sig)
    await placeImage(sig, viewCenterWorld(), 200)
    close()
  }

  return (
    <Modal.Backdrop isOpen={isOpen} onOpenChange={onOpenChange}>
      <Modal.Container>
        <Modal.Dialog className="sm:max-w-lg">
          {({ close }) => (
            <>
              <Modal.CloseTrigger />
              <Modal.Header>
                <Modal.Icon className="bg-default text-foreground"><Signature size={18} /></Modal.Icon>
                <Modal.Heading>Your signature</Modal.Heading>
              </Modal.Header>
              <Modal.Body>
                <p className="mb-3 text-sm text-muted">Sign in the box. It's saved in this browser so you can place it again with <kbd className="font-sans font-medium text-foreground">S</kbd>.</p>
                <canvas
                  ref={ref}
                  className="h-44 w-full touch-none rounded-xl border border-dashed border-border bg-white"
                  onPointerDown={(e) => { e.currentTarget.setPointerCapture(e.pointerId); last.current = pt(e); line(pt(e)); setEmpty(false) }}
                  onPointerMove={(e) => { if (last.current) line(pt(e)) }}
                  onPointerUp={() => { last.current = null }}
                />
              </Modal.Body>
              <Modal.Footer>
                <Button variant="ghost" onPress={() => { const c = ref.current!; c.getContext('2d')!.clearRect(0, 0, c.width, c.height); setEmpty(true) }}>Clear</Button>
                <Button isDisabled={empty} onPress={() => save(close)}>Save and place</Button>
              </Modal.Footer>
            </>
          )}
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  )
}
