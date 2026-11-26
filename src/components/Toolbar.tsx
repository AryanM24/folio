import { Button, Kbd, Separator, Tooltip } from '@heroui/react'
import {
  ArrowUpRight, Circle, Eraser, Hand, Highlighter, ImagePlus, MousePointer2, Pen, Minus, Signature, Square, StickyNote, Type, SquareSlash,
} from 'lucide-react'
import type { Tool } from '../lib/types'
import { setTool, useStore, getState, viewCenterWorld } from '../store'
import { pickFiles, placeImage, readDataUrl } from '../lib/files'

export const TOOLS: { id: Tool; label: string; key: string; icon: typeof Pen }[][] = [
  [
    { id: 'select', label: 'Select', key: 'V', icon: MousePointer2 },
    { id: 'hand', label: 'Hand', key: 'H', icon: Hand },
  ],
  [
    { id: 'pen', label: 'Pen', key: 'P', icon: Pen },
    { id: 'highlighter', label: 'Highlighter', key: 'M', icon: Highlighter },
    { id: 'eraser', label: 'Eraser', key: 'E', icon: Eraser },
  ],
  [
    { id: 'text', label: 'Text', key: 'T', icon: Type },
    { id: 'sticky', label: 'Sticky note', key: 'N', icon: StickyNote },
    { id: 'rect', label: 'Rectangle', key: 'R', icon: Square },
    { id: 'ellipse', label: 'Ellipse', key: 'O', icon: Circle },
    { id: 'line', label: 'Line', key: 'L', icon: Minus },
    { id: 'arrow', label: 'Arrow', key: 'A', icon: ArrowUpRight },
  ],
  [
    { id: 'redact', label: 'Redact', key: 'X', icon: SquareSlash },
    { id: 'image', label: 'Image', key: 'I', icon: ImagePlus },
    { id: 'signature', label: 'Signature', key: 'S', icon: Signature },
  ],
]

/** Image and signature are one-shot actions, not modes. */
export async function activateTool(t: Tool, openSignature: () => void) {
  if (t === 'image') {
    const [f] = await pickFiles('image/*', false)
    if (f) await placeImage(await readDataUrl(f))
    return
  }
  if (t === 'signature') {
    const sig = getState().signature
    if (sig) placeImage(sig, viewCenterWorld(), 200)
    else openSignature()
    return
  }
  setTool(t)
}

export function Toolbar({ openSignature }: { openSignature: () => void }) {
  const tool = useStore((s) => s.tool)
  return (
    <div className="pointer-events-auto flex flex-col items-center gap-0.5 rounded-xl border border-border bg-overlay p-1 shadow-[var(--overlay-shadow)]">
      {TOOLS.map((group, gi) => (
        <div key={gi} className="flex flex-col gap-0.5">
          {gi > 0 && <Separator className="my-1 w-6 self-center" />}
          {group.map((t) => (
            <Tooltip key={t.id} delay={300} closeDelay={0}>
              <Button
                isIconOnly
                size="sm"
                variant={tool === t.id ? 'primary' : 'ghost'}
                aria-label={t.label}
                aria-pressed={tool === t.id}
                onPress={() => activateTool(t.id, openSignature)}
              >
                <t.icon size={17} strokeWidth={1.75} />
              </Button>
              <Tooltip.Content placement="right" className="flex items-center gap-2">
                {t.label} <Kbd variant="light"><Kbd.Content>{t.key}</Kbd.Content></Kbd>
              </Tooltip.Content>
            </Tooltip>
          ))}
        </div>
      ))}
    </div>
  )
}
