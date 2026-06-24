# PodiumSwiftApp — Enhancement Overview

## Goal

Make the SwiftUI macOS app a complete, first-class replacement for the Podium web dashboard.
No browser tab needed.

## Design Philosophy

### Native, not ported

The web dashboard emulates glassmorphism with CSS `backdrop-filter` and fake blur layers.
The Swift app should use what macOS Sequoia 15.4+ ships natively:

- **Liquid Glass** — Apple's new `.glassEffect()` modifier (not `.ultraThinMaterial`)
- **Vibrancy** — real NSVisualEffectView-backed materials where appropriate
- **Sidebar chrome** — `NavigationSplitView` with the native system sidebar blur
- **Toolbar** — native `NSToolbar` feel, not floating HStack rows
- **Menus** — context menus, right-click, full keyboard shortcut coverage
- **Window chrome** — traffic-light buttons visible, title bar integration

### macOS first

The app runs on Mac, so it should feel like a Mac app, not a React SPA in a window:
- Resizable split panels that respect user drag preference
- `List` selection that drives a detail panel (not a sheet/modal)
- Status item (menu-bar icon) for quick stats without opening the window
- Standard ⌘-number shortcuts for tab switching
- `NSFontPanel`, `NSColorPanel` integration where it helps users

## Scope of This Spec

The spec covers 6 documents:

| File | What it covers |
|---|---|
| `SPEC-OVERVIEW.md` | This file — goals and philosophy |
| `SPEC-DESIGN.md` | Liquid Glass design system, tokens, component rules |
| `SPEC-FEATURES.md` | Every missing feature — wireframe-level description |
| `SPEC-API.md` | New API client methods and models required |
| `SPEC-ARCHITECTURE.md` | File layout, navigation graph, new models |

## Minimum macOS Target

**macOS 26** (or 15.4 Sequoia with the Liquid Glass API backport — verify at build time).

The new `.glassEffect()` API shipped in iOS 26 / macOS 26. If the target is 15.x, we fall back to `.ultraThinMaterial` for cards but preserve the spec intent throughout.

## What Exists Today

| View | Status |
|---|---|
| Dashboard (stats + live feed) | ✅ Done |
| Sessions list + detail | ✅ Done |
| Analytics charts | ✅ Done |
| Settings (server URL only) | ✅ Done, needs extension |
| Activity Feed (standalone) | ❌ Missing |
| Workflows (DAG + graphs) | ❌ Missing |
| Kanban Board | ❌ Missing |
| Run (spawn Claude subprocess) | ❌ Missing |
| Search (global Cmd+F) | ❌ Missing |
| CC Config Explorer | ❌ Missing |
| Notifications | ❌ Missing |
| Menu-bar status item | ❌ Missing |
| Import Sessions | ❌ Missing |
