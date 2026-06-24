# PodiumSwiftApp — Design System Spec

## Liquid Glass (macOS 26 / iOS 26)

Apple's Liquid Glass is not just vibrancy — it's a new rendering layer with:
- Real specular highlights that respond to window position and light angle
- Dynamic tint that picks up the content behind the glass
- Morphing geometry: two adjacent glass surfaces merge at their edges
- A distinct "gel" feel vs the flat frosted look of `.ultraThinMaterial`

### API to use

```swift
// Primary card surface
someView
    .glassEffect()

// Interactive glass (button, pill)
someView
    .glassEffect(.regular.interactive())

// Tinted glass (accent panels)
someView
    .glassEffect(.regular.tint(.blue))

// Merged/connected panels (sidebar + content share one bubble)
GlassEffectContainer(spacing: 0) {
    Sidebar()
    DetailPanel()
}
```

### Fallback for macOS 15.x

If compiling for macOS 15.x, wrap in an `#if swift(>=6.0)` / availability check and use:

```swift
// Fallback
.background(.ultraThinMaterial)
.overlay(
    RoundedRectangle(cornerRadius: radius)
        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
)
```

### Migration plan for Theme.swift

Replace `GlassCardModifier` and `glassBackground()`:
- Remove the manual `RoundedRectangle + strokeBorder + shadow` stack
- Replace with `.glassEffect()` directly on content views
- Keep `Theme.cornerRadius` as the shape's `cornerRadius` param

---

## Design Tokens

### Colors

Keep existing semantic colors — they read well on glass:

```swift
// Status colors (unchanged)
active/working  → .cyan
completed       → Color(r:0.2, g:0.9, b:0.55)
error           → Color(r:1, g:0.35, b:0.35)
abandoned       → Color(r:0.9, g:0.6, b:0.1)
waiting         → Color(r:0.9, g:0.85, b:0.2)

// New accent
primary         → Color.accentColor  (let macOS pick from system accent)
surface         → .clear (glass handles it)
```

### Typography

Use system font at standard sizes — no custom fonts needed:

| Role | Font |
|---|---|
| Title | `.title2.weight(.semibold)` |
| Section header | `.headline` |
| Body | `.body` |
| Label | `.callout` |
| Secondary | `.subheadline.foregroundStyle(.secondary)` |
| Caption | `.caption.foregroundStyle(.tertiary)` |
| Monospace numbers | `.monospacedDigit()` suffix |

### Spacing

```swift
enum Spacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 40
}
```

### Corner radii

```swift
enum Radius {
    static let pill:   CGFloat = 999   // badges, buttons
    static let card:   CGFloat = 16    // primary cards
    static let inner:  CGFloat = 10    // nested elements
    static let small:  CGFloat = 6     // tags, chips
}
```

---

## Component Catalogue

### GlassCard

The primary container. Replaces the current `glassCard()` modifier.

```
┌────────────────────────────────┐  ← .glassEffect(), radius 16
│  [icon]  Title                 │
│  ─────────────────────────────│
│  content                       │
└────────────────────────────────┘
```

Rules:
- Never nest two GlassCards — use `GlassEffectContainer` to merge them
- Min height: 80pt
- Internal padding: 16pt

### StatCard

Used on Dashboard, inline mini version for SessionDetail.

```
┌──────────────┐
│  ⬢  Icon    │  ← tinted glass (.glassEffect(.regular.tint(color)))
│              │
│  1,234       │  ← .title2.monospacedDigit()
│  Agents      │  ← .caption, secondary
│  of 5,678    │  ← .caption2, tertiary
└──────────────┘
```

### SidebarRow

Standard `Label` with optional badge. The sidebar itself gets `.glassEffect()` behind the `List`.

Badge rules:
- Active count → `.cyan` fill, white text
- Total count → secondary foreground, no background

### StatusBadge

Pill with colored background at 20% opacity, border at 40%:

```swift
Text(label)
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(color.opacity(0.2))
    .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
    .clipShape(Capsule())
```

### LiveBadge

Pulsing red dot + "LIVE" text. Use `.symbolEffect(.pulse)` on the dot.

### AgentTreeRow

Indented row for agent hierarchy in SessionDetail:

```
  ├─ [●] Agent Name          working
  │    └─ [◦] Child Agent   completed
```

Indentation: 20pt per depth level. Status dot uses `.symbolEffect(.pulse)` when active.

### ChartView

Wrap SwiftUI Charts. Each chart view gets a GlassCard container.
- Use `.chartBackground` to tint the chart area with `.ultraThinMaterial` (chart plots look better on a slightly lighter surface than raw glass)
- Gradient fills: stop opacity at 0.6 at top, 0 at bottom

---

## Native macOS Patterns

### Window

```swift
.windowStyle(.titleBar)             // show title bar, not hiddenTitleBar
.windowToolbarStyle(.unified)       // toolbar merges with title bar
.defaultSize(width: 1200, height: 760)
.windowResizability(.contentMinSize)
```

Title: "Podium" (static, not the selected tab name)

### Sidebar

`NavigationSplitView` with `.balanced` style. Sidebar min width: 220pt, max: 280pt.
Do NOT use a `TabView` — keep the split-view pattern.

### Toolbar

Primary toolbar items:
- (leading) App icon + "Podium" title (already done)
- (trailing) ConnectionBanner, LiveBadge, Refresh button
- (trailing, new) Search button → triggers `searchable` on the active view
- (trailing, new) Settings button → opens Settings sheet

Keyboard shortcuts:
```
⌘1  → Dashboard
⌘2  → Sessions
⌘3  → Analytics
⌘4  → Activity Feed
⌘5  → Workflows
⌘6  → Kanban
⌘7  → Run
⌘F  → Focus search field (context-aware)
⌘,  → Settings
```

### Context Menus

Sessions list rows: right-click → `Copy session ID`, `View in detail`, `Mark as abandoned`
Agent tree rows: right-click → `Copy agent ID`, `Copy prompt`

### Menu Bar Status Item

A `MenuBarExtra` that shows:
- Active session count (dot + number)
- Last event summary
- Quick "Open Podium" action
- Shows/hides the main window

```swift
MenuBarExtra("Podium", systemImage: "gauge.with.dots.needle.67percent") {
    MenuBarContent()
}
.menuBarExtraStyle(.window)  // popover style, not menu style
```

---

## Animation Guidelines

- Use `withAnimation(.spring(response: 0.35, dampingFraction: 0.8))` for panel transitions
- Session rows: `.transition(.move(edge: .leading).combined(with: .opacity))`
- Stats cards: `.transition(.scale(scale: 0.95).combined(with: .opacity))`
- Live event rows: slide in from bottom, `.transition(.push(from: .bottom))`
- Avoid `DispatchQueue.main.asyncAfter` for animations — use `.task` and `async/await`
- Pulsing dots: `.symbolEffect(.pulse, options: .repeating)` (SF Symbol animation)
