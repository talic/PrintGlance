import AppKit
import SwiftUI

@main
struct PrintGlanceApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var model: GlanceModel

    init() {
        let model = GlanceModel()
        model.start()
        _model = StateObject(wrappedValue: model)
        AppDelegate.model = model
        DispatchQueue.main.async { SetupWindow.showIfNeeded(model: model) }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: GlanceModel?

    /// Opening the app from Finder while no printer is set up shows setup.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let model = Self.model {
            SetupWindow.showIfNeeded(model: model)
        }
        return false
    }

    /// Closing the setup window must not quit a menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
