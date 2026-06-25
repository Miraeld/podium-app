# Xcode Migration Guide — PodiumApp + PodiumWidget

This guide explains how to move from the current `swift build` + `run.sh` setup to a full
Xcode project that enables the WidgetKit extension. Two paths are provided: **Path A** (fast,
uses xcodegen) and **Path B** (manual, pure Xcode GUI).

---

## Why This Migration Is Needed

The current `swift build` / `run.sh` pipeline produces an **unsigned** `.app` bundle. That
works fine day-to-day — Spotlight indexing, App Intents, `podium://` deep links, and the main
UI all function without code signing.

**WidgetKit is the exception.** A Widget Extension is a separate process that:

1. Runs inside a **sandboxed XPC service** — it must be a distinct Xcode target.
2. Shares data with the host app via an **App Group** — which requires a provisioning profile
   issued by Apple's servers.
3. Must be **embedded and signed** inside the host `.app` bundle at build time.

None of these three steps are achievable with a bare `Package.swift` executable. The Xcode
project (via either path below) wires all three together automatically.

### What Still Works in the Unsigned Build

- `run.sh` / `swift build` — continue to use for day-to-day development; the SPM build is
  kept working in parallel (the Xcode project references the same `Sources/PodiumApp/` files).
- `WidgetStore.save()` / `WidgetStore.load()` — the `WidgetStore` helper degrades gracefully:
  when the App Group suite `group.com.gaelrobin.PodiumApp` is unavailable (unsigned), it falls
  back to `UserDefaults.standard`. The main app **will not crash** — it just writes to the
  standard defaults instead of the shared container. The widget only receives real data once the
  App Group entitlement is active (i.e., after the Xcode build is signed and run).

---

## Path A — Fast (xcodegen)

### Prerequisites

- Xcode 26.5 installed (you already have this)
- Homebrew installed

### Steps

```bash
# 1. Install xcodegen (one-time)
brew install xcodegen

# 2. Generate the Xcode project from project.yml
cd /path/to/PodiumSwiftApp-native
xcodegen generate

# 3. Open the generated project
open Podium.xcodeproj
```

**What `project.yml` already handles** (no manual steps needed):
- Both the `Podium` app target and `PodiumWidget` extension target are defined.
- `Sources/PodiumApp/WidgetData.swift` is added to **both** targets so the shared types
  compile in the widget without importing the app module.
- App Group `group.com.gaelrobin.PodiumApp` is wired to both targets via entitlements files.
- The `podium://` URL scheme and `NSUserActivityTypes` are set in the app's Info.plist.
- The widget is marked for embedding inside the app bundle (`embed: true`).

**After opening Xcode:**

```
4. In Xcode → Project navigator → select "Podium" project
5. Select the "Podium" target → Signing & Capabilities tab
   → Set "Team" to your Apple Developer account
6. Select the "PodiumWidget" target → Signing & Capabilities tab
   → Set the same Team
7. Press ⌘R (build & run)
```

> **Note:** If you see "No matching provisioning profiles found," make sure you are signed into
> Xcode with your Apple ID (Xcode → Settings → Accounts) and that both bundle IDs
> (`com.gaelrobin.PodiumApp` and `com.gaelrobin.PodiumApp.widget`) exist in the Apple Developer
> portal, or let Xcode manage signing automatically.

---

## Path B — Manual (Xcode GUI only)

Use this if you prefer not to install xcodegen, or if `xcodegen generate` produces an
unexpected result.

### Step 1 — Create the Xcode project

1. Open Xcode → **File → New → Project**
2. Select **macOS → App** → click Next
3. Fill in:
   - **Product Name:** `Podium`
   - **Bundle Identifier:** `com.gaelrobin.PodiumApp`
   - **Language:** Swift
   - **Interface:** SwiftUI
4. Uncheck "Include Tests" (tests live in SPM)
5. Save next to the existing repo (or inside it — does not matter)

### Step 2 — Set deployment target

6. Select the **Podium project** in the navigator → **Podium target** → General tab
7. Set **macOS Deployment Target** to `14.0`

### Step 3 — Replace the default source files

8. Delete the auto-generated `ContentView.swift` and `PodiumApp.swift` placeholders
   (Move to Trash)
9. In Finder, select all files in `Sources/PodiumApp/` and drag them into the Xcode
   project navigator under the `Podium` group
10. In the "Choose options" sheet: check **"Copy items if needed"** = NO (reference in place),
    **"Add to targets"** = `Podium` ✓

### Step 4 — Add App Group to the app target

11. Select **Podium target** → **Signing & Capabilities** tab → **+ Capability**
12. Add **App Groups** → click `+` → enter `group.com.gaelrobin.PodiumApp` → OK
13. Xcode generates `Podium.entitlements` automatically. Verify it contains:
    ```xml
    <key>com.apple.security.application-groups</key>
    <array><string>group.com.gaelrobin.PodiumApp</string></array>
    ```
    (You can replace this auto-generated file with the pre-built `PodiumApp.entitlements`
    from the repo root if you prefer.)

### Step 5 — Add the Widget Extension target

14. **File → New → Target** → select **Widget Extension** → Next
15. Fill in:
    - **Product Name:** `PodiumWidget`
    - **Bundle Identifier:** `com.gaelrobin.PodiumApp.widget`
    - **Include Configuration Intent:** NO (static configuration)
16. Click **Finish** — Xcode creates the `PodiumWidget/` group with a default template

### Step 6 — Add App Group to the widget target

17. Select **PodiumWidget target** → **Signing & Capabilities** tab → **+ Capability**
18. Add **App Groups** → check `group.com.gaelrobin.PodiumApp`

### Step 7 — Replace widget template with the real implementation

19. Delete the auto-generated template file inside the `PodiumWidget` group (Move to Trash)
20. Drag `PodiumWidget/PodiumWidget.swift` from this repo into the `PodiumWidget` Xcode group
    - Add to target: **PodiumWidget** ✓ (not Podium)
    - Copy items if needed: NO

### Step 8 — Add WidgetData.swift to BOTH targets

`WidgetData.swift` must compile in both the app and the widget (they are separate processes).

21. In Xcode, select `Sources/PodiumApp/WidgetData.swift` in the navigator
22. Open the **File Inspector** (right panel → first tab)
23. Under **Target Membership**, check **both** `Podium` ✓ and `PodiumWidget` ✓

### Step 9 — Configure the app Info.plist

24. Open the app target's `Info.plist` and add:

    **`CFBundleURLTypes`** (for `podium://` deep links):
    ```xml
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key>
        <string>com.gaelrobin.PodiumApp.url</string>
        <key>CFBundleURLSchemes</key>
        <array><string>podium</string></array>
      </dict>
    </array>
    ```

    **`NSUserActivityTypes`** (for Spotlight / session deep links):
    ```xml
    <key>NSUserActivityTypes</key>
    <array>
      <string>com.gaelrobin.PodiumApp.viewSession</string>
    </array>
    ```

### Step 10 — Set signing teams

25. Select **Podium target** → Signing & Capabilities → set **Team**
26. Select **PodiumWidget target** → Signing & Capabilities → set the same **Team**
27. Press **⌘R** — build and run

---

## Keeping `run.sh` Working (Dual Build System)

`Package.swift` continues to compile all `Sources/PodiumApp/*.swift` files, including
`WidgetData.swift`. The SPM build does not include the widget extension target (it has no
`Package.swift` entry), so `swift build` remains green and `run.sh` works as before.

Day-to-day workflow recommendation:
- Use `./run.sh` for rapid iteration on the main app UI (no signing required, ~3 s build).
- Use Xcode when you need to test the widget, App Intents, or any extension target.
- The two build systems share the same source files; changes you make to `.swift` files under
  `Sources/PodiumApp/` are reflected in both builds automatically.

---

## App Store / Notarization (optional future step)

Once you are ready to distribute beyond your own Mac:

1. In Xcode, set `CODE_SIGN_STYLE = Manual` and select a Distribution certificate.
2. **Product → Archive** → Distribute → Developer ID (notarized).
3. The unsigned `run.sh` path is unaffected and continues to work for local development.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Widget shows "No data yet" even after the app runs | Verify the App Group ID matches exactly in both entitlements files. Check Console.app for "container lookup failed" errors. |
| `xcodegen generate` fails with "unknown target type" | Update xcodegen: `brew upgrade xcodegen`. Requires ≥ 2.40. |
| Build error: "WidgetSnapshot redefined" | `WidgetData.swift` was accidentally added to both targets AND reimported from the app module. Remove the duplicate — target membership (Step 8) is the correct approach. |
| Widget does not appear in Notification Center | On macOS, widgets require at least one successful signed build; re-launch the app after first Xcode build to register the extension. |
| `run.sh` fails after Xcode migration | The SPM build is independent of Xcode. If `swift build` fails, check that you did not accidentally edit `Package.swift` or any file in `Sources/PodiumApp/`. |
