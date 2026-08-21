import AppKit
import SwiftUI

extension View {
    /// MenuBarExtra `.window` on Tahoe draws a glass panel larger than the
    /// SwiftUI content. Apps behind it show through, and a second grouped
    /// card sits inside empty chrome. Hug the panel to the view and paint it
    /// opaque so the glance is one card.
    func hugMenuBarPanel() -> some View {
        modifier(HugMenuBarPanel())
    }
}

private struct HugMenuBarPanel: ViewModifier {
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        opaque(content)
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, new in size = new }
                }
            }
            .background(MenuBarPanelHost(size: size))
    }

    @ViewBuilder
    private func opaque(_ content: Content) -> some View {
        let fill = Color(nsColor: .windowBackgroundColor)
        if #available(macOS 15.0, *) {
            content
                .containerBackground(fill, for: .window)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background(fill)
        } else {
            content.background(fill)
        }
    }
}

private struct MenuBarPanelHost: NSViewRepresentable {
    var size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view, attempt: 0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView, attempt: 0) }
    }

    private func apply(to view: NSView, attempt: Int) {
        guard let window = view.window else {
            if attempt < 2 {
                DispatchQueue.main.async { apply(to: view, attempt: attempt + 1) }
            }
            return
        }
        configure(window)
    }

    private func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.hasShadow = true
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.styleMask.remove([.titled, .closable, .miniaturizable, .resizable])

        if let root = window.contentView?.superview ?? window.contentView {
            flattenVibrancy(root)
        }

        guard size.width > 1, size.height > 1 else { return }
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        guard abs(window.frame.width - frameSize.width) > 0.5
            || abs(window.frame.height - frameSize.height) > 0.5
        else { return }
        var frame = window.frame
        frame.origin.y += frame.height - frameSize.height
        frame.size = frameSize
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    private func flattenVibrancy(_ view: NSView) {
        if let fx = view as? NSVisualEffectView {
            fx.material = .windowBackground
            fx.blendingMode = .withinWindow
            fx.state = .followsWindowActiveState
        }
        for child in view.subviews {
            flattenVibrancy(child)
        }
    }
}
