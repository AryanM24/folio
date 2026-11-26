# Design

Folio's look is a SwiftUI port of [HeroUI v3](https://heroui.com)'s default theme. Colors, radii, control heights and shadows come straight from `@heroui/styles@3.2.8`. OKLCH values are converted to sRGB, and `color-mix()` tokens are pre-mixed in OKLab. The port lives in `Sources/FolioKit/Design/`.

The rule is simple: **use Hero tokens and components, not raw colors or ad-hoc styling.** System menus, alerts, open/save panels and the Find bar stay native. Everything Folio draws itself uses Hero.

## Tokens (`Hero.*`)

Every color adapts to light and dark mode.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `background` | `#F5F5F5` | `#060607` | Window background behind content |
| `backgroundSecondary` | `#EBEBEB` | `#0C0C0E` | Canvas behind pages and sheets |
| `surface` | `#FFFFFF` | `#18181B` | Cards, sidebars, status bar |
| `surfaceSecondary` | `#EFEFF0` | `#232325` | Nested surfaces, hovered rows |
| `overlay` | `#FFFFFF` | `#18181B` | Popovers, inspectors, floating toolbars |
| `foreground` | `#18181B` | `#FCFCFC` | Primary text |
| `muted` | `#71717A` | `#9F9FA9` | Secondary text, labels, icons |
| `default` / `defaultHover` | `#EBEBEC` / `#E1E1E2` | `#27272A` / `#2E2E31` | Neutral fills: secondary buttons, chips, tracks |
| `border` / `separator` | `#DEDEE0` / `#E4E4E7` | `#28282C` / `#212124` | Hairlines |
| `accent` | `#0485F7` | `#0485F7` | The one primary action, selection, focus |
| `accentSoft` / `accentSoftForeground` | 15% accent / `#1E63AE` | 12% accent / `#61A8FB` | Selected toggles, active tabs in toolbars |
| `danger`, `dangerSoft`, `success`, `warning` | | | Status only |

### Radii (`Hero.Radius`)

`sm 4` · `md 6` · `lg 8` · `xl 12` (fields, tooltips) · `xxl 16` (chips, menu items) · `track 20` (segmented control track) · `xxxl 24` (cards, modals). Pill buttons use a capsule.

Nested corners are concentric: an inner radius equals the outer radius minus the padding between them.

## Components

| HeroUI | Folio | Notes |
| --- | --- | --- |
| `Button` | `.buttonStyle(.hero(.primary))` | Variants: `primary`, `secondary`, `tertiary`, `outline`, `ghost`, `danger`, `dangerSoft`. Sizes: `.sm` 32, `.md` 36, `.lg` 40. Options: `iconOnly`, `fullWidth`, `isSelected` (toolbar toggles). |
| `Card` | `.heroCard()` | Surface fill, 24 pt corners, layered shadow in light mode only |
| `Popover` / overlay | `.heroOverlay()` | Inspectors, floating toolbars, HUDs |
| `Input` | `.textFieldStyle(.hero)` | 36 pt tall, 12 pt corners, accent focus ring |
| `Tabs` | `HeroTabs(options, selection:)` | Segmented control with a sliding pill |
| `Switch` | `.toggleStyle(.hero)` | 40×20 track |
| `Slider` | `HeroSlider("Opacity", value:, in:)` | Label and value on top, accent fill |
| `Chip` | `HeroChip("Draft", tone: .accent)` | Status labels |
| `Kbd` | `HeroKbd("⌘K")` | Shortcut hints |
| Toolbar | `HeroToolbar { … }` + `HeroToolbarDivider()` | Floating tool pill over a canvas |

`StatusBar`, `InspectorSection`, `ColorSwatches` and `BusyOverlay` (in `FolioKit/Views.swift`) are built from these tokens.

## Rules

- **One primary button per view.** Everything else is `secondary`, `tertiary` or `ghost`.
- **Toolbars are ghost icon buttons**: `.hero(.ghost, size: .sm, iconOnly: true, isSelected:)`, with a `.help("Bold ⌘B")` tooltip.
- **Type:** the system font. 13 pt for UI, 12 pt for labels, 11 pt for chips and status. Weights are regular and medium; semibold only for titles. Use sentence case and no all-caps labels. Apply `.monospacedDigit()` wherever numbers change.
- **Icons:** SF Symbols in the text's color, usually `Hero.muted`. Never give an icon its own color, except for the accent on a selected tool.
- **Spacing** is on a 4 pt grid. Use 16 pt panel padding, 8 pt between controls in a group, and 16–24 pt between groups.
- **Motion:** `Hero.animation` (150 ms ease-out) for state changes, and a 0.97 press scale (built into Hero buttons). No looping animations and no bounce.
- **Dark mode is checked for every screen.** Use `SCHEME=dark scripts/snapshot.sh`.
- **Accessibility:** every icon-only control has an accessibility label (a `Label` with `iconOnly` keeps its title for VoiceOver). Everything is reachable from the keyboard, and the menu bar lists every command with its shortcut.
