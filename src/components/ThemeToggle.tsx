import { useState } from 'react'
import { Button, Tooltip } from '@heroui/react'
import { Moon, Sun } from 'lucide-react'

export function ThemeToggle() {
  const [dark, setDark] = useState(() => document.documentElement.classList.contains('dark'))
  const toggle = () => {
    const next = !dark
    const el = document.documentElement
    el.classList.toggle('dark', next)
    el.dataset.theme = next ? 'dark' : 'light'
    localStorage.setItem('folio:theme', next ? 'dark' : 'light')
    setDark(next)
  }
  return (
    <Tooltip delay={400}>
      <Button isIconOnly size="sm" variant="ghost" aria-label="Toggle theme" onPress={toggle}>
        {dark ? <Sun size={16} /> : <Moon size={16} />}
      </Button>
      <Tooltip.Content>{dark ? 'Light mode' : 'Dark mode'}</Tooltip.Content>
    </Tooltip>
  )
}
