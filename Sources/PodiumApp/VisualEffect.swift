#if os(macOS)
import SwiftUI
import AppKit

// NSVisualEffectView wrapper that blurs the desktop BEHIND the window.
// SwiftUI materials (.ultraThinMaterial etc.) use .withinWindow blending by default,
// which only blurs content inside the app. .behindWindow blending is what gives
// the Control Center / Notification panel "see-through to wallpaper" effect.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

// Configures the host NSWindow for translucency from within the SwiftUI
// view hierarchy — more reliable than AppDelegate because the window
// is guaranteed to exist when updateNSView fires.
struct WindowTranslucencyAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window, window.isOpaque else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
    }
}

#endif
