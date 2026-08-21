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
        } label: {
            StripLabel(strip: model.strip)
                .id(model.strip)
        }
        .menuBarExtraStyle(.window)
    }
}
