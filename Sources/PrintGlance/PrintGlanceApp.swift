import AppKit
import SwiftUI

@main
struct PrintGlanceApp: App {
    @StateObject private var model: GlanceModel

    init() {
        let model = GlanceModel()
        model.start()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            GlanceView(model: model)
                .hugMenuBarPanel()
        } label: {
            // Do not `.id(strip)`: on macOS 26 that recreates the extra and it
            // never returns to the bar.
            StripLabel(strip: model.strip)
                .background(PinMenuBarExtra())
        }
        .menuBarExtraStyle(.window)
    }
}

/// Tahoe parks unnamed extras at x≈80, under the front app's menus.
private struct PinMenuBarExtra: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { pin(view, attempt: 0) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { pin(view, attempt: 0) }
    }

    private func pin(_ view: NSView, attempt: Int) {
        guard let window = view.window, let screen = NSScreen.main else {
            if attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    pin(view, attempt: attempt + 1)
                }
            }
            return
        }
        var frame = window.frame
        let bar = screen.frame
        guard frame.minX < bar.midX else { return }
        frame.origin.x = bar.maxX - max(frame.width, 80) - 320
        window.setFrame(frame, display: true)
    }
}
