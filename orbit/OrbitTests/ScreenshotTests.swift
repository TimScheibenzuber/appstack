#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Orbit

/// Renders the real views with sample content into PNGs. Runs only when ORBIT_SHOTS names an output folder
/// (CI passes TEST_RUNNER_ORBIT_SHOTS).
@MainActor
struct ScreenshotTests {
    static let output = ProcessInfo.processInfo.environment["ORBIT_SHOTS"]

    @Test(.enabled(if: ScreenshotTests.output != nil))
    func captureScreens() async throws {
        let out = URL(fileURLWithPath: Self.output!, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let vaultDir = FileManager.default.temporaryDirectory.appending(path: "orbit-shots-\(UUID().uuidString)")
        defer {
            VaultLocation.forget()
            try? FileManager.default.removeItem(at: vaultDir)
        }

        let store = Store()
        try await store.create(at: vaultDir, password: "screenshots")
        store.addSampleContent()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RootView().environment(store))
        window.makeKeyAndOrderFront(nil)

        func shot(_ name: String, wait: Double = 1.6) async throws {
            try await Task.sleep(for: .seconds(wait))
            guard let image = Self.capture(window) else { return }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appending(path: name + ".png"))
        }

        let items = store.items.values
        try await shot("1-overview", wait: 2.5)
        store.scope = .all
        store.mode = .list
        store.selection = Set(items.filter { $0.title == "Launch plan v2" }.map(\.id))
        try await shot("2-list")
        store.mode = .board
        try await shot("3-board")
        store.mode = .graph
        store.selection = []
        try await shot("4-graph", wait: 5)
        if let chat = items.first(where: { $0.kind == .chat }) {
            store.mode = .list
            store.selection = [chat.id]
            try await shot("5-chat")
        }
        if let map = items.first(where: { $0.kind == .mindmap }) {
            store.focused = map.id
            try await shot("6-mindmap")
            store.focused = nil
        }
        store.showPalette = true
        try await shot("7-palette")
        store.showPalette = false
        store.lock(manual: true)
        try await shot("0-lock")
    }

    /// The composited window, including Liquid Glass and Metal layers that `cacheDisplay` can't draw.
    /// `CGWindowListCreateImage` is hidden from the SDK but still captures the app's own windows.
    static func capture(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let capture = unsafeBitCast(symbol, to: Capture.self)
            if let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue() { return image }
        }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}
#endif
