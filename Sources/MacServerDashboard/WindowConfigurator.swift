import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    var pinned: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                Self.configure(window, pinned: pinned)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                Self.configure(window, pinned: pinned)
            }
        }
    }

    static func applyToAllWindows(pinned: Bool) {
        for window in NSApplication.shared.windows {
            configure(window, pinned: pinned)
        }
    }

    static func configure(_ window: NSWindow, pinned: Bool) {
        window.title = "Mac Server Dashboard"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        if pinned {
            window.level = Self.clickableDesktopLevel
        } else {
            window.level = .normal
        }

        if window.frame.width < 420 || window.frame.height < 560 {
            let visibleFrame = NSScreen.main?.visibleFrame ?? .init(x: 80, y: 80, width: 1200, height: 800)
            let size = NSSize(width: 500, height: 680)
            let origin = NSPoint(x: visibleFrame.maxX - size.width - 24, y: visibleFrame.maxY - size.height - 24)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    private static var clickableDesktopLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
}
