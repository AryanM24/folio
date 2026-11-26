import { useRef } from 'react'
import { Button, ColorSwatchPicker, Label, Separator, Slider, ToggleButton, ToggleButtonGroup, Tooltip, parseColor } from '@heroui/react'
import {
  AlignCenter, AlignLeft, AlignRight, ArrowDownToLine, ArrowUpToLine, Bold, Copy, Lock, Trash2, Unlock,
} from 'lucide-react'
import type { Obj } from '../lib/types'
import { checkpoint, deleteSelection, reorder, setDoc, setState, setStyle, updateObjects, useStore, type Style } from '../store'
import { uid } from '../lib/storage'
import { moveObj } from '../lib/geometry'

const INK = ['#1f2937', '#ef4444', '#f97316', '#eab308', '#22c55e', '#3b82f6', '#8b5cf6', '#ffffff']
const FILLS = ['transparent', '#fee2e2', '#ffedd5', '#fef9c3', '#dcfce7', '#dbeafe', '#ede9fe', '#1f2937']
const STICKIES = ['#fde68a', '#fecaca', '#fed7aa', '#bbf7d0', '#bfdbfe', '#ddd6fe', '#f5f5f4']
const REDACT = ['#000000', '#ffffff']

function Swatches({ label, colors, value, onChange }: { label: string; colors: string[]; value?: string; onChange: (c: string) => void }) {
  return (
    <div className="flex flex-col gap-1.5">
      <span className="text-xs text-muted">{label}</span>
      <ColorSwatchPicker
        aria-label={label}
        size="sm"
        value={value && value !== 'transparent' ? parseColor(value) : undefined}
        onChange={(c) => onChange(c.toString('hex').toLowerCase())}
        className="flex-wrap gap-1.5"
      >
        {colors.map((c) =>
          c === 'transparent' ? (
            <button
              key={c}
              aria-label="No fill"
              onClick={() => onChange('transparent')}
              className={`size-6 rounded-full border border-border bg-[linear-gradient(135deg,transparent_45%,var(--color-danger)_45%,var(--color-danger)_55%,transparent_55%)] ${value === 'transparent' ? 'ring-2 ring-accent ring-offset-2 ring-offset-overlay' : ''}`}
            />
          ) : (
            <ColorSwatchPicker.Item key={c} color={c}>
              <ColorSwatchPicker.Swatch className={c === '#ffffff' || c === '#f5f5f4' ? 'shadow-[inset_0_0_0_1px_var(--color-border)]' : ''} />
              <ColorSwatchPicker.Indicator />
            </ColorSwatchPicker.Item>
          ),
        )}
      </ColorSwatchPicker>
    </div>
  )
}

function Range({ label, value, min, max, step = 1, fmt, onChange }: { label: string; value: number; min: number; max: number; step?: number; fmt?: (v: number) => string; onChange: (v: number, final: boolean) => void }) {
  return (
    <Slider
      value={value}
      minValue={min}
      maxValue={max}
      step={step}
      onChange={(v) => onChange(v as number, false)}
      onChangeEnd={(v) => onChange(v as number, true)}
      className="w-full"
    >
      <div className="flex justify-between text-xs">
        <Label className="text-muted">{label}</Label>
        <span className="tabular-nums">{fmt ? fmt(value) : value}</span>
      </div>
      <Slider.Track>
        <Slider.Fill />
        <Slider.Thumb />
      </Slider.Track>
    </Slider>
  )
}

const has = (o: Obj, k: string) => k in o

export function Inspector() {
  const selection = useStore((s) => s.selection)
  const objects = useStore((s) => s.doc.objects)
  const tool = useStore((s) => s.tool)
  const style = useStore((s) => s.style)
  const live = useRef(false)
  const sel = objects.filter((o) => selection.includes(o.id))
  const first = sel[0]

  const drawing = ['pen', 'text', 'rect', 'ellipse', 'line', 'arrow', 'sticky'].includes(tool)
  if (!first && !drawing) return null

  /** Apply to selection (slider drags merge into one undo step) or to defaults for new objects. */
  function apply(patch: Partial<Record<string, unknown>>, stylePatch: Partial<Style>, final = true) {
    setStyle(stylePatch)
    if (!sel.length) return
    const ids = sel.map((o) => o.id)
    const fn = (o: Obj) => {
      const p = Object.fromEntries(Object.entries(patch).filter(([k]) => has(o, k)))
      return Object.keys(p).length ? ({ ...o, ...p } as Obj) : o
    }
    if (final && !live.current) return updateObjects(ids, fn)
    if (!live.current) { checkpoint(); live.current = true }
    setDoc((d) => ({ ...d, objects: d.objects.map((o) => (ids.includes(o.id) ? fn(o) : o)) }))
    if (final) live.current = false
  }

  const types = new Set(sel.length ? sel.map((o) => o.type) : [tool === 'pen' ? 'path' : tool])
  const any = (...t: string[]) => t.some((x) => types.has(x as Obj['type']))
  const stroke = (first && ('stroke' in first ? first.stroke : 'color' in first ? first.color : undefined)) ?? style.stroke
  const fill = (first && 'fill' in first ? first.fill : undefined) ?? style.fill
  const width = (first && 'strokeWidth' in first ? first.strokeWidth : undefined) ?? style.strokeWidth
  const opacity = first?.opacity ?? style.opacity
  const fontSize = (first && 'fontSize' in first ? first.fontSize : undefined) ?? style.fontSize
  const text = first?.type === 'text' ? first : null
  const locked = sel.length > 0 && sel.every((o) => o.locked)

  function duplicate() {
    const clones = sel.map((o) => ({ ...moveObj(o, 16, 16), id: uid() }))
    checkpoint()
    setDoc((d) => ({ ...d, objects: [...d.objects, ...clones] }))
    setState({ selection: clones.map((c) => c.id) })
  }

  return (
    <div
      className="pointer-events-auto flex w-60 flex-col gap-4 rounded-xl border border-border bg-overlay p-3.5 shadow-[var(--overlay-shadow)]"
      onPointerDown={(e) => e.stopPropagation()}
    >
      <div className="text-xs font-medium">
        {sel.length > 1 ? `${sel.length} objects` : first ? NAMES[first.type] : `New ${NAMES[[...types][0] as Obj['type']]?.toLowerCase() ?? 'object'}`}
      </div>

      {any('path', 'line', 'arrow', 'rect', 'ellipse', 'text') && !(sel.length && sel.every((o) => o.type === 'path' && o.highlighter)) && (
        <Swatches label={any('text') && !any('path', 'line', 'arrow', 'rect', 'ellipse') ? 'Color' : 'Stroke'} colors={INK} value={stroke} onChange={(c) => apply({ stroke: c, color: c }, { stroke: c })} />
      )}
      {any('rect', 'ellipse') && <Swatches label="Fill" colors={FILLS} value={fill} onChange={(c) => apply({ fill: c }, { fill: c })} />}
      {any('sticky') && <Swatches label="Note color" colors={STICKIES} value={sel.length ? fill : style.sticky} onChange={(c) => apply({ fill: c }, { sticky: c })} />}
      {any('redact') && <Swatches label="Cover" colors={REDACT} value={fill} onChange={(c) => apply({ fill: c }, {})} />}

      {any('path', 'line', 'arrow', 'rect', 'ellipse') && (
        <Range label="Stroke width" value={width} min={0} max={any('path') && sel.some((o) => o.type === 'path' && o.highlighter) ? 48 : 24} onChange={(v, f) => apply({ strokeWidth: v }, { strokeWidth: v }, f)} />
      )}
      {any('text', 'sticky') && <Range label="Font size" value={fontSize} min={8} max={96} onChange={(v, f) => apply({ fontSize: v }, { fontSize: v }, f)} />}
      {!any('redact') && <Range label="Opacity" value={Math.round(opacity * 100)} min={5} max={100} fmt={(v) => `${v}%`} onChange={(v, f) => apply({ opacity: v / 100 }, { opacity: v / 100 }, f)} />}

      {text && (
        <div className="flex items-center gap-2">
          <ToggleButton size="sm" isIconOnly aria-label="Bold" isSelected={!!text.bold} onChange={(b) => apply({ bold: b }, {})}><Bold size={15} /></ToggleButton>
          <ToggleButtonGroup
            size="sm"
            selectionMode="single"
            disallowEmptySelection
            selectedKeys={[text.align ?? 'left']}
            onSelectionChange={(k) => apply({ align: [...k][0] }, {})}
          >
            <ToggleButton id="left" isIconOnly aria-label="Align left"><AlignLeft size={15} /></ToggleButton>
            <ToggleButton id="center" isIconOnly aria-label="Align center"><ToggleButtonGroup.Separator /><AlignCenter size={15} /></ToggleButton>
            <ToggleButton id="right" isIconOnly aria-label="Align right"><ToggleButtonGroup.Separator /><AlignRight size={15} /></ToggleButton>
          </ToggleButtonGroup>
        </div>
      )}

      {sel.length > 0 && (
        <>
          <Separator />
          <div className="flex items-center justify-between">
            <Act label="Bring to front" kbd="]" onPress={() => reorder('front')}><ArrowUpToLine size={15} /></Act>
            <Act label="Send to back" kbd="[" onPress={() => reorder('back')}><ArrowDownToLine size={15} /></Act>
            <Act label="Duplicate" kbd="⌘D" onPress={duplicate}><Copy size={15} /></Act>
            <Act label={locked ? 'Unlock' : 'Lock'} kbd="⇧⌘L" onPress={() => updateObjects(sel.map((o) => o.id), (o) => ({ ...o, locked: !locked }))}>{locked ? <Unlock size={15} /> : <Lock size={15} />}</Act>
            <Act label="Delete" kbd="⌫" danger onPress={deleteSelection}><Trash2 size={15} /></Act>
          </div>
        </>
      )}
    </div>
  )
}

function Act({ label, kbd, danger, onPress, children }: { label: string; kbd: string; danger?: boolean; onPress: () => void; children: React.ReactNode }) {
  return (
    <Tooltip delay={300} closeDelay={0}>
      <Button isIconOnly size="sm" variant={danger ? 'danger-soft' : 'ghost'} aria-label={label} onPress={onPress}>{children}</Button>
      <Tooltip.Content>{label} <span className="ml-1 text-muted">{kbd}</span></Tooltip.Content>
    </Tooltip>
  )
}

export const NAMES: Record<Obj['type'], string> = {
  path: 'Drawing', line: 'Line', arrow: 'Arrow', rect: 'Rectangle', ellipse: 'Ellipse', text: 'Text', sticky: 'Sticky note', image: 'Image', redact: 'Redaction',
}

