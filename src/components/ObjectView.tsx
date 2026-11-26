import { memo } from 'react'
import type { Obj, Pt } from '../lib/types'
import { FONT, LINE_H, wrapText } from '../lib/geometry'

export const STICKY_PAD = 14

function smoothPath(pts: Pt[]) {
  if (pts.length < 2) return pts.length ? `M${pts[0][0]} ${pts[0][1]}h0.01` : ''
  let d = `M${pts[0][0]} ${pts[0][1]}`
  for (let i = 1; i < pts.length - 1; i++) {
    const [x, y] = pts[i]
    const [nx, ny] = pts[i + 1]
    d += ` Q${x} ${y} ${(x + nx) / 2} ${(y + ny) / 2}`
  }
  const [lx, ly] = pts[pts.length - 1]
  return d + ` L${lx} ${ly}`
}

function Lines({ lines, x, y, size, color, bold, anchor }: { lines: string[]; x: number; y: number; size: number; color: string; bold?: boolean; anchor: 'start' | 'middle' | 'end' }) {
  return (
    <text x={x} y={y} fontFamily={FONT} fontSize={size} fontWeight={bold ? 700 : 400} fill={color} textAnchor={anchor} style={{ whiteSpace: 'pre' }}>
      {lines.map((l, i) => (
        <tspan key={i} x={x} dy={i === 0 ? size : size * LINE_H}>
          {l || ' '}
        </tspan>
      ))}
    </text>
  )
}

/** Pure SVG for one object. Shared by the canvas and PDF export. */
export const ObjectView = memo(function ObjectView({ o, hideText }: { o: Obj; hideText?: boolean }) {
  const common = { 'data-id': o.id, opacity: o.opacity } as const
  switch (o.type) {
    case 'path': {
      const d = smoothPath(o.points)
      return (
        <g {...common} style={o.highlighter ? { mixBlendMode: 'multiply' } : undefined}>
          <path d={d} fill="none" stroke="transparent" strokeWidth={Math.max(14, o.strokeWidth + 8)} strokeLinecap="round" />
          <path d={d} fill="none" stroke={o.stroke} strokeWidth={o.strokeWidth} strokeLinecap={o.highlighter ? 'butt' : 'round'} strokeLinejoin="round" />
        </g>
      )
    }
    case 'line':
    case 'arrow': {
      const [[x1, y1], [x2, y2]] = o.points
      const a = Math.atan2(y2 - y1, x2 - x1)
      const len = Math.max(10, o.strokeWidth * 4)
      const head = (s: number) => [x2 - len * Math.cos(a + s), y2 - len * Math.sin(a + s)]
      const [hx1, hy1] = head(0.45)
      const [hx2, hy2] = head(-0.45)
      return (
        <g {...common}>
          <line x1={x1} y1={y1} x2={x2} y2={y2} stroke="transparent" strokeWidth={Math.max(14, o.strokeWidth + 8)} />
          <line x1={x1} y1={y1} x2={x2} y2={y2} stroke={o.stroke} strokeWidth={o.strokeWidth} strokeLinecap="round" />
          {o.type === 'arrow' && (
            <path d={`M${hx1} ${hy1} L${x2} ${y2} L${hx2} ${hy2}`} fill="none" stroke={o.stroke} strokeWidth={o.strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
          )}
        </g>
      )
    }
    case 'rect':
      return <rect {...common} x={o.x} y={o.y} width={o.w} height={o.h} rx={2} fill={o.fill} stroke={o.stroke} strokeWidth={o.strokeWidth} pointerEvents="all" />
    case 'ellipse':
      return <ellipse {...common} cx={o.x + o.w / 2} cy={o.y + o.h / 2} rx={o.w / 2} ry={o.h / 2} fill={o.fill} stroke={o.stroke} strokeWidth={o.strokeWidth} pointerEvents="all" />
    case 'redact':
      return <rect {...common} x={o.x} y={o.y} width={o.w} height={o.h} fill={o.fill} />
    case 'image':
      return <image {...common} href={o.src} x={o.x} y={o.y} width={o.w} height={o.h} preserveAspectRatio="none" />
    case 'text': {
      const anchor = o.align === 'center' ? 'middle' : o.align === 'right' ? 'end' : 'start'
      const tx = o.align === 'center' ? o.x + o.w / 2 : o.align === 'right' ? o.x + o.w : o.x
      return (
        <g {...common}>
          <rect x={o.x} y={o.y} width={o.w} height={o.h} fill="transparent" />
          {!hideText && <Lines lines={wrapText(o.text, o.fontSize, o.w, o.bold)} x={tx} y={o.y} size={o.fontSize} color={o.color} bold={o.bold} anchor={anchor} />}
        </g>
      )
    }
    case 'sticky': {
      const lines = wrapText(o.text, o.fontSize, o.w - STICKY_PAD * 2)
      const th = o.fontSize + (lines.length - 1) * o.fontSize * LINE_H
      return (
        <g {...common}>
          <rect x={o.x + 2} y={o.y + 4} width={o.w} height={o.h} rx={4} fill="#000" opacity={0.08} />
          <rect x={o.x} y={o.y} width={o.w} height={o.h} rx={4} fill={o.fill} />
          {!hideText && <Lines lines={lines} x={o.x + o.w / 2} y={o.y + Math.max(STICKY_PAD, (o.h - th) / 2)} size={o.fontSize} color="#1c1917" anchor="middle" />}
        </g>
      )
    }
  }
})
