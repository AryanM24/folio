import { useEffect, useState } from 'react'
import { Library } from './components/Library'
import { Editor } from './components/Editor'

const route = () => location.hash.match(/^#\/d\/(.+)$/)?.[1] ?? null
export const openDoc = (id: string | null) => { location.hash = id ? `/d/${id}` : '' }

export default function App() {
  const [docId, setDocId] = useState(route)
  useEffect(() => {
    const f = () => setDocId(route())
    addEventListener('hashchange', f)
    return () => removeEventListener('hashchange', f)
  }, [])
  return docId ? <Editor key={docId} docId={docId} /> : <Library />
}
