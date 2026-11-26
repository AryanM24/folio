export type Pt = [number, number]

export interface Page {
  id: string
  /** source PDF id, or null for a blank page */
  src: string | null
  /** 0-based page index inside the source */
  index: number
  /** unrotated size in PDF points */
  w: number
  h: number
  /** extra rotation applied by the user, multiple of 90 */
  rotation: number
}

interface Base {
  id: string
  opacity: number
  locked?: boolean
}

export interface PathObj extends Base {
  type: 'path'
  points: Pt[]
  stroke: string
  strokeWidth: number
  highlighter?: boolean
}
export interface LineObj extends Base {
  type: 'line' | 'arrow'
  points: [Pt, Pt]
  stroke: string
  strokeWidth: number
}
export interface BoxBase extends Base {
  x: number
  y: number
  w: number
  h: number
}
export interface ShapeObj extends BoxBase {
  type: 'rect' | 'ellipse'
  stroke: string
  fill: string
  strokeWidth: number
}
export interface RedactObj extends BoxBase {
  type: 'redact'
  fill: string
}
export interface TextObj extends BoxBase {
  type: 'text'
  text: string
  fontSize: number
  color: string
  bold?: boolean
  align?: 'left' | 'center' | 'right'
}
export interface StickyObj extends BoxBase {
  type: 'sticky'
  text: string
  fill: string
  fontSize: number
}
export interface ImageObj extends BoxBase {
  type: 'image'
  src: string
}

export type Obj = PathObj | LineObj | ShapeObj | RedactObj | TextObj | StickyObj | ImageObj
export type ObjType = Obj['type']

export interface DocState {
  pages: Page[]
  objects: Obj[]
}

export interface DocMeta {
  id: string
  name: string
  createdAt: number
  updatedAt: number
  pageCount: number
  thumb?: string
}

export type Tool =
  | 'select' | 'hand' | 'pen' | 'highlighter' | 'eraser' | 'text' | 'sticky'
  | 'rect' | 'ellipse' | 'line' | 'arrow' | 'redact' | 'image' | 'signature'

export interface Box { x: number; y: number; w: number; h: number }
