// LinuxStub.swift
//
// PodiumApp is a macOS-only SwiftUI product — every other file in this
// target is wrapped in `#if os(macOS)`. On Linux none of that code compiles,
// which leaves the target with no entry point and a broken link step for
// `swift build` / `swift test` (which build every target unless you pass
// `--product`). This file supplies a trivial fallback `main` so the target
// always links on non-macOS platforms; it does nothing at runtime and isn't
// a supported way to run Podium on Linux — use `podium-server` for that.

#if !os(macOS)
@main
struct LinuxStubMain {
    static func main() {
        print("PodiumApp is macOS-only. Use `podium-server` on Linux.")
    }
}
#endif
