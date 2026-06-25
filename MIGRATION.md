# Make the Widget Live — FREE (no Apple Developer Program needed)

This guide shows how to enable the PodiumWidget WidgetKit extension using only a
**free personal Apple ID** — no $99/yr Apple Developer Program account required.

---

## Why Xcode Is Still Needed (Even for Free)

The `swift build` / `run.sh` pipeline produces an unsigned `.app` bundle. That
works perfectly for day-to-day development of the main app — no signing, no Xcode.

**WidgetKit is the exception.** A Widget Extension is a separate sandboxed XPC
process that must be:

1. A distinct Xcode target (SPM has no concept of extension bundles).
2. Embedded and code-signed inside the host `.app` at build time.
3. Granted specific sandbox entitlements (at minimum, `network.client` to reach
   the Podium server).

All three steps require an Xcode build. The good news: they do **not** require a
paid Developer account. A free personal Apple ID (the "Personal Team" Xcode shows
when you add an account) is sufficient.

### What Changed vs. the App-Group Approach

The previous scaffold shared data between the app and widget via an App Group
(`group.com.gaelrobin.PodiumApp`). **App Groups require a paid account** because
Apple must register the group ID against your paid team.

The new approach is simpler and free:

- The widget fetches live data **directly** from `http://localhost:4820` using its
  own `URLSession`. It calls `/api/stats` and `/api/sessions?limit=6` on every
  timeline refresh.
- The widget needs only the `com.apple.security.network.client` entitlement
  (outgoing connections), which is available to free personal teams.
- No App Group capability is wired to either target. No shared `WidgetData.swift`
  membership is needed; the widget is fully standalone.
- The main app target (`PodiumApp.entitlements`) no longer contains any App Group
  or sandbox entitlement — it stays unsandboxed, exactly as it runs via `run.sh`.

---

## Path A — Fast (xcodegen)

### Prerequisites

- Xcode installed (16 or later)
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

**After opening Xcode:**

```
4. Project navigator → select "Podium" project → "Podium" target
   → Signing & Capabilities tab
   → Team: pick your personal (free) Apple ID team
     ("Add an Account…" if not listed, then choose the Personal Team entry)

5. Select the "PodiumWidget" target → Signing & Capabilities tab
   → Team: same personal (free) Apple ID team

6. Press ⌘R (build & run)
```

No App Group capability to add. The widget's `network.client` entitlement is
already set in `PodiumWidget/PodiumWidget.entitlements` and wired via `project.yml`.

> **Tip:** If Xcode shows "Signing requires a development team — select a
> development team in the Signing & Capabilities editor," simply select your
> Personal Team and click "Try Again." Xcode will auto-provision a development
> certificate for you at no cost.

---

## Path B — Manual (Xcode GUI only)

Use this if you prefer not to install xcodegen, or want to understand every step.

### Step 1 — Create the Xcode project

1. Xcode → **File → New → Project**
2. **macOS → App** → Next
3. Fill in:
   - **Product Name:** `Podium`
   - **Bundle Identifier:** `com.gaelrobin.PodiumApp`
   - **Language:** Swift / **Interface:** SwiftUI
4. Uncheck "Include Tests" → Finish

### Step 2 — Set deployment target

5. Select the **Podium project** → **Podium target** → General tab
6. Set **macOS Deployment Target** to `14.0`

### Step 3 — Replace the default source files

7. Delete the auto-generated `ContentView.swift` and `<AppName>App.swift` (Move to Trash)
8. In Finder, select all files in `Sources/PodiumApp/` and drag them into the Xcode
   project navigator under the `Podium` group
9. "Choose options" sheet: **Copy items if needed** = NO, **Add to targets** = `Podium` ✓

### Step 4 — Add the Widget Extension target

10. **File → New → Target** → **Widget Extension** → Next
11. Fill in:
    - **Product Name:** `PodiumWidget`
    - **Bundle Identifier:** `com.gaelrobin.PodiumApp.widget`
    - **Include Configuration Intent:** NO (static configuration)
12. Finish

### Step 5 — Set personal (free) team on both targets

13. **Podium target** → Signing & Capabilities → **Team:** your personal Apple ID
14. **PodiumWidget target** → Signing & Capabilities → **Team:** same personal Apple ID

### Step 6 — Add network-client entitlement to the widget

15. **PodiumWidget target** → Signing & Capabilities → **+ Capability**
16. Add **App Sandbox** → this enables the sandbox and creates an entitlements file
17. In the sandbox capability panel, check **Outgoing Connections (Client)**
    — this adds `com.apple.security.network.client = true`

    Alternatively, replace the auto-generated entitlements file with
    `PodiumWidget/PodiumWidget.entitlements` from this repo (already contains the
    correct keys).

> **Do NOT add App Groups** — it is not needed and requires a paid account.

### Step 7 — Replace the widget template with the real implementation

18. Delete the auto-generated template `.swift` file in the `PodiumWidget` Xcode group
19. Drag `PodiumWidget/PodiumWidget.swift` from this repo into the group
    - Add to target: **PodiumWidget** ✓ (not Podium)
    - Copy items if needed: NO

The widget is **standalone** — `WidgetData.swift` is NOT added to the widget target.

### Step 8 — Configure the app Info.plist

20. Open the app target's `Info.plist` and add:

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

### Step 9 — Build and run

21. Press **⌘R** — Xcode builds both the app and the widget, signs them with your
    free personal team certificate, and launches the app.

---

## Keeping `run.sh` Working (Dual Build System)

`Package.swift` + `run.sh` continue to compile all `Sources/PodiumApp/*.swift`
files for day-to-day development. The SPM build does not include the widget
extension target (it has no `Package.swift` entry), so `swift build` remains
green and `run.sh` works as before.

Day-to-day recommendation:
- `./run.sh` — rapid iteration on the main app UI (~3 s build, no signing needed).
- Xcode — when you need to test the widget, or any other extension target.
- Changes to files under `Sources/PodiumApp/` are reflected in both builds.

Note: `Sources/PodiumApp/WidgetData.swift` is now unused by the widget (the
widget fetches its own data). The app may still write to it harmlessly. It can be
removed from the app target in a future cleanup pass.

---

## Caveats

- **Widget refresh cadence:** WidgetKit controls the exact refresh schedule. The
  widget requests a new timeline approximately every 5 minutes, but WidgetKit may
  adjust this based on system load and power state. There are no push-triggered
  refreshes on the free path.
- **Server must be running:** The widget fetches from `localhost:4820`. If the
  Podium server is not running, the widget shows a "Podium server not running"
  state and retries on the next scheduled refresh.
- **Host/port:** The base URL is hardcoded to `http://localhost:4820` (Podium's
  default). If you run the server on a different port, update the `podiumBaseURL`
  constant at the top of `PodiumWidget/PodiumWidget.swift`. A paid-account
  App-Group alternative would let the widget read the app's configured host/port
  from a shared `UserDefaults` container — but that requires the $99/yr program.
- **No live-push updates:** On the App-Group path, the main app could call
  `WidgetCenter.shared.reloadAllTimelines()` after every WebSocket `stats_update`
  to push instant refreshes. On the free localhost-fetch path this is not possible
  (the widget is a separate sandboxed process with no IPC channel to the app).
  The widget refreshes on its own ~5-minute schedule instead.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Widget shows "Podium server not running" | Make sure the Podium server is running: `/podium start` from the Podium project directory. |
| Widget shows stale data | WidgetKit controls cadence. Force a refresh: remove and re-add the widget in Notification Center. |
| `xcodegen generate` fails with "unknown target type" | Update xcodegen: `brew upgrade xcodegen`. Requires ≥ 2.40. |
| Signing error: "No matching provisioning profile" | In Signing & Capabilities, make sure the Team is set to your Personal Team (not "None"). Let Xcode manage signing automatically. |
| `run.sh` fails after Xcode migration | The SPM build is independent of Xcode. If `swift build` fails, check that you did not accidentally edit `Package.swift` or any file in `Sources/PodiumApp/`. |
| Widget does not appear in Notification Center | On macOS, widgets register after at least one successful signed build. Re-launch the app after the first Xcode build. |
