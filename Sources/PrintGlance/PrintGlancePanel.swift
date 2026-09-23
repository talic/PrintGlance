import AppKit
import SwiftUI

extension View {
    /// MenuBarExtra `.window` on Tahoe draws a glass panel larger than the
    /// SwiftUI content. Hug the panel to the view. Keep the system frost.
    func hugMenuBarPanel() -> some View {
        modifier(HugMenuBarPanel())
    }
}

private struct HugMenuBarPanel: ViewModifier {
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        sized(content)
    }

    @ViewBuilder
    private func sized(_ content: Content) -> some View {
        let view = content
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, new in size = new }
                }
            }
            .background(MenuBarPanelHost(size: size))
        if #available(macOS 15.0, *) {
            view.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            view
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.styleMask.remove([.titled, .closable, .miniaturizable, .resizable])

        if let root = window.contentView?.superview ?? window.contentView {
            restoreFrost(root)
        }

        if size.width > 1, size.height > 1 {
            let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            if abs(window.frame.width - frameSize.width) > 0.5
                || abs(window.frame.height - frameSize.height) > 0.5 {
                var frame = window.frame
                frame.origin.y += frame.height - frameSize.height
                frame.size = frameSize
                window.setFrame(frame, display: true)
                window.invalidateShadow()
            }
        }
        // Geometry can report the stretched panel, which locks the extra band in.
        hugDrawnContent(window)
    }

    /// The card stays centered in a taller clear panel. Trim that band.
    private func hugDrawnContent(_ window: NSWindow) {
        guard let content = window.contentView, let host = findHosting(content) else { return }
        guard let target = drawnContentSize(in: host) else { return }
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: target)).size
        guard window.frame.height - frameSize.height > 8 else { return }
        var frame = window.frame
        frame.origin.y += (frame.height - frameSize.height) / 2
        frame.size.height = frameSize.height
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    /// Text and controls, plus the card padding. Clear space around them does not count.
    private func drawnContentSize(in host: NSView) -> CGSize? {
        var box: CGRect?
        func walk(_ view: NSView) {
            let name = String(describing: type(of: view))
            let drawn = name.contains("CGDrawing") || name.contains("Button") || name.contains("Image")
            if drawn, !view.isHidden {
                let rect = view.convert(view.bounds, to: host)
                if rect.width > 2, rect.height > 2 {
                    box = box.map { $0.union(rect) } ?? rect
                }
            }
            for child in view.subviews { walk(child) }
        }
        walk(host)
        guard let box, box.height > 20, box.minY.isFinite else { return nil }
        let pad: CGFloat = box.minY > 20 ? 16 : min(box.minY, 16)
        let height = box.minY > 20 ? box.height + pad * 2 : box.maxY + pad
        let windowHeight = host.window?.frame.height ?? height
        guard height + 8 < host.frame.height || height + 8 < windowHeight else { return nil }
        let width = host.frame.width > 40 ? host.frame.width : box.width + pad * 2
        return CGSize(width: width, height: ceil(height))
    }

    private func findHosting(_ view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("HostingView") { return view }
        for child in view.subviews {
            if let found = findHosting(child) { return found }
        }
        return nil
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
