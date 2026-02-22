**Overview**
This document defines the Algedonia UI system modeled after Linear’s interaction design. It is the source of truth for visual tokens, layout rules, components, and motion. Use it across all screens to keep the product consistent.

**Principles**
- Clarity over decoration
- Dense but breathable spacing
- Subtle motion only when it adds feedback
- Fast scanning of metadata
- Consistent alignment and rhythm

**Typography**
Primary font: `Inter UI`
Monospace: `Azeret Mono`
Base size: `13px`
Line height: `1.45`
Title sizes:
- Page title: `text-sm` with `font-semibold`
- Section title: `text-sm` with `font-semibold`
- Label: `text-[11px]` uppercase tracking
Text colors:
- Primary: `var(--color-fg)`
- Secondary: `var(--color-fg-secondary)`
- Muted: `var(--color-fg-muted)`

**Color Tokens**
Background:
- App surface: `--color-surface`
- Raised surface: `--color-surface-raised`
- Panel surface: `--color-surface-panel`
- Sidebar surface: `--color-surface-sidebar`
Borders:
- Standard: `--color-border`
- Soft: `--color-border-soft`
Accents:
- Primary: `--color-accent-indigo`
- Hover: `--color-accent-indigo-hover`
Status:
- Green: `--color-status-green`
- Red: `--color-status-red`
- Orange: `--color-status-orange`
- Yellow: `--color-status-yellow`
- Blue: `--color-status-blue`
- Cyan: `--color-status-cyan`
Shadows:
- Soft: `--color-shadow-soft`
- Strong: `--color-shadow-strong`

**Spacing**
Baseline spacing unit: `4px`
Common paddings:
- Header height: `h-12`
- Card padding: `p-3.5`
- Panel padding: `p-5`
Gaps:
- Tight: `gap-2`
- Standard: `gap-3`
- Loose: `gap-4`

**Radii**
Use small rounding everywhere:
- Buttons, fields: `rounded-md`
- Cards and panels: `rounded-xl`
- Pills: `rounded-full`

**Layout**
App shell:
- Left sidebar fixed `w-64`
- Main content uses `flex-1` and scrolls
Headers:
- Consistent `h-12` top bar
- Title left, controls right
Columns:
- Boards use `min-w-72` per column
- Horizontal scroll allowed for overflow

**Interaction Design**
Hover:
- Use subtle `hover:bg-surface-raised` or `hover:text-fg`
Focus:
- Use `focus:outline-none` and border highlight
Buttons:
- Primary: accent background
- Secondary: surface-raised background
Drag-and-drop:
- Smooth animation `150ms`
- Ghost item opacity `0.4`
- Chosen state includes soft shadow and slight rotation
Navigation:
- Sidebar selection uses raised background
- View toggles use subtle accent fill

**Motion**
Modal transitions:
- 300ms ease-out in
- 200ms ease-in out
Drag:
- `animation: 150` for Sortable
Hover transitions:
- `transition-colors` for text and background

**Components**
Button
- Primary: `bg-accent-indigo text-white`
- Secondary: `bg-surface-raised text-fg`
- Sizes: small `px-3 py-1.5`, medium `px-4 py-2`

Icon Button
- Size `size-6` or `size-7`
- Hover uses raised surface

Sidebar Item
- Default: muted text
- Active: raised background and primary text

Board Column
- Header contains status icon, label, count
- Column list is scrollable, uses `gap-2`

Ticket Card
- Panel background and soft border
- Title + meta row (priority, id, type, assignee)
- Hover raises border and background

Ticket Row
- Single-line layout
- Priority icon, id, status, title, type, assignee
- Hover uses raised background

Modal
- Blur overlay
- Rounded corners with strong shadow
- Close button in top right

Markdown
- Use `.markdown` class for all rendered markdown
- Links use accent color and underline on hover
- Code blocks use panel background and border

Presence
- Small avatars with `size-4` or `size-5`
- Clustered with `-space-x-1`

Tables
- Panel background with border
- Header row uses raised surface
- Row hover uses raised surface

**Forms**
Input
- Panel background, border, small font
- Focus border uses accent
Textarea
- Same as input with min height
Select
- Same as input with smaller size

**Examples**
Primary button:
`class="px-4 py-1.5 bg-accent-indigo hover:bg-accent-indigo-hover text-white text-xs font-medium rounded-md"`

Card:
`class="rounded-xl border border-border bg-surface-panel p-5"`

Header:
`class="h-12 border-b border-border flex items-center justify-between px-6 bg-surface"`

**Usage Rules**
- Use the design tokens above instead of hard-coded colors
- Keep density consistent across list and board views
- No gradients, glass, or strong shadows unless specified
- Keep text sizes small and weights medium
- Motion should never feel springy or bouncy
