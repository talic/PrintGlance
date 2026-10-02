import AppKit
import SwiftUI

extension View {
    /// MenuBarExtra `.window` on Tahoe leaves a clear band above and below the card.
    /// Snap the panel to the card. Keep the system frost.
    func hugMenuBarPanel() -> some View {
        modifier(HugMenuBarPanel())
    }
}

private struct HugMenuBarPanel: ViewModifier {
    func body(content: Content) -> some View {
        let view = content
            .fixedSize()
            .background(MenuBarPanelHost())
        if #available(macOS 15.0, *) {
            view.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            view
        }
    }
}

/// Calls `action` each time the menu bar panel becomes key, which is each time it opens.
struct PanelOpened: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyWatchView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyWatchView)?.action = action
    }

    private final class KeyWatchView: NSView {
        var action: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(becameKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func becameKey() {
            action?()
        }
    }
}

/// Window frame that matches the card, keeping the top and trailing edges.
enum MenuBarHug {
    static func frame(current: CGRect, fitting: CGSize) -> CGRect? {
        guard fitting.width > 40, fitting.height > 40 else { return nil }
        guard abs(current.width - fitting.width) > 1
            || abs(current.height - fitting.height) > 1 else { return nil }
        return CGRect(
            x: current.maxX - fitting.width,
            y: current.maxY - fitting.height,
            width: fitting.width,
            height: fitting.height
        )
    }
}

private struct MenuBarPanelHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HugWindowView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HugWindowView)?.hug()
    }
}

/// Sits behind the fixed-size card, so its size is the card's size.
private final class HugWindowView: NSView {
    private var hugging = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowSized),
            name: NSWindow.didResizeNotification,
            object: window
        )
        hug()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The card grew or shrank. The window's minimum size catches up a turn later, and only
    /// growing forces a resize, so a shrink would leave the panel tall.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hug()
    }

    @objc private func windowSized() {
        hug()
    }

    fileprivate func hug() {
        guard !hugging, let window else { return }
        style(window)
        let fitting = window.frameRect(forContentRect: NSRect(origin: .zero, size: bounds.size)).size
        guard let frame = MenuBarHug.frame(current: window.frame, fitting: fitting) else { return }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
        hugging = true
        window.setFrame(frame, display: true)
        window.invalidateShadow()
        hugging = false
    }

    private func style(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.styleMask.remove([.titled, .closable, .miniaturizable, .resizable])
        if let root = window.contentView?.superview ?? window.contentView {
            restoreFrost(root)
        }
    }

    private func restoreFrost(_ view: NSView) {
        if let fx = view as? NSVisualEffectView {
            fx.blendingMode = .behindWindow
            fx.state = .active
            if fx.material == .windowBackground {
                fx.material = .popover
            }
        }
        for child in view.subviews {
            restoreFrost(child)
        }
    }
}
