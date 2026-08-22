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
        }
        .menuBarExtraStyle(.window)
    }
}
