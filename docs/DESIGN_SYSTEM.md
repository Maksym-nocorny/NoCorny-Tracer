# NoCorny Tracer — Design System

Design tokens extracted from `Theme.swift` and `DesignSystem.swift`. Used by both the macOS app and the web platform (`tracer.nocorny.com`).

---

## Colors

### Brand

| Token | Value | Usage |
|-------|-------|-------|
| Brand Purple | `#3E0693` | Primary brand color, buttons, links |
| Light Purple | `#6B00DE` | Secondary accent, gradient endpoint |
| Pink | `#FF08DE` | Highlight accent |
| Orange | `#FF6900` | Warning, attention |
| Yellow | `#FFC72C` | Info, badge |
| Red | `#F9423A` | Error, destructive actions |
| Green | `#00C040` | Success, positive status |

### Backgrounds

| Token | Light | Dark |
|-------|-------|------|
| Primary | `#FFFFFF` | `#1C1C1E` |
| Secondary | `#EEEEEE` | `#2C2C2E` |
| Card | `#F5F3F7` | `#2A2830` |
| Neutral | `#FBF9FD` | `#2A2830` |
| Tab Active | `#FFFFFF` | `#3A3A3C` |

### Text

| Token | Light | Dark |
|-------|-------|------|
| Primary | `#212121` | `#F0F0F0` |
| Secondary | `#444444` | `#AAAAAA` |
| Tertiary | `#666666` | `#888888` |
| Alternate | `#FFFFFF` | `#FFFFFF` |

### Neutrals (light mode reference)

| Token | Value |
|-------|-------|
| Lightest | `#EEEEEE` |
| Lighter | `#CCCCCC` |
| Light | `#AAAAAA` |

### Gradients

| Token | Light | Dark |
|-------|-------|------|
| Primary | `#3E0693` → `#6B00DE` | `#A855F7` → `#C084FC` |
| Danger | `#D92D20` → `#F9423A` | same |
| Neutral | `#555555` → `#777777` | same |

---

## Typography

### Fonts

| Role | Font Family | Fallback |
|------|------------|----------|
| Heading | **PT Sans** (Bold, Regular) | System sans-serif |
| Body | **Mulish** (variable: Light–Bold) | System sans-serif |
| Monospace | System monospace | — |

### Usage

- **Headings**: PT Sans Bold. Default weight `bold`.
- **Body text**: Mulish. Default weight `medium`. Available: light, regular, medium, semibold, bold.
- **Size offset**: +1pt applied globally in macOS app (all sizes are `size + 1`).

---

## Spacing

| Token | Value |
|-------|-------|
| `xs` | 4px |
| `sm` | 6px (Theme) / 8px (DesignSystem) |
| `md` | 8px (Theme) / 12px (DesignSystem) |
| `lg` | 12px (Theme) / 20px (DesignSystem) |
| `xl` | 16px |
| `xxl` | 20px (Theme) / 40px (DesignSystem) |
| `xxxl` | 24px (Theme) / 64px (DesignSystem) |
| `section` | 32px |

For the web, use the `Theme.swift` scale: **4 / 6 / 8 / 12 / 16 / 20 / 24 / 32**.

---

## Border Radius

| Token | Value |
|-------|-------|
| `sm` | 4px |
| `md` | 12px |
| `lg` | 16px |
| `xl` | 24px |
| `pill` | 9999px |

---

## Shadows

### Base
`0 1px 2px rgba(0,0,0,0.05)`

### Card
```
0 4px 4px rgba(0,0,0,0.1),
0 2px 2px rgba(0,0,0,0.06)
```

### Card Hover
```
0 12px 8px rgba(0,0,0,0.08),
0 4px 3px rgba(0,0,0,0.03)
```

### Dropdown
```
0 20px 12px rgba(0,0,0,0.08),
0 8px 4px rgba(0,0,0,0.03)
```

### Card (Theme.swift variant)
- Default: `0 2px 8px rgba(0,0,0,0.08)`
- Hover: `0 4px 12px rgba(0,0,0,0.12)`
- Dark mode: `0 2px 8px rgba(0,0,0,0.3)`

### Card border
- Light: `1px solid rgba(0,0,0,0.06)`
- Dark: `1px solid rgba(255,255,255,0.08)`

---

## Animation

| Token | Easing | Duration |
|-------|--------|----------|
| Standard | ease-in-out | 200ms |
| Smooth | ease-in-out | 500ms |

---

## Card Style

Standard card component pattern:
- Padding: 16px (`xl`)
- Background: Card background (adaptive)
- Border radius: 12px (`md`)
- Border: 1px, adaptive opacity
- Shadow: Card shadow, stronger in dark mode

---

## Dark Mode

Both light and dark themes are fully supported. The system uses adaptive color pairs that switch based on user preference. The web platform should:
- Default to system preference (`prefers-color-scheme`)
- Provide a manual toggle
- Use the exact adaptive color pairs listed above
