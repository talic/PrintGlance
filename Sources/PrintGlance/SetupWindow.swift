import AppKit
import SwiftUI

/// Adds or edits a printer in its own window. The menu bar panel closes when you click
/// elsewhere, and people walk to the printer to read the access code.
@MainActor
enum SetupWindow {
    enum Mode: Equatable {
        case add
        case edit(serial: String)
    }

    private static var window: NSWindow?
    private static var flow: SetupFlow?
    private static let delegate = Delegate()

    /// Add mode, or edit mode for a half-entered printer, while no printer is set up.
    static func showIfNeeded(model: GlanceModel) {
        guard !model.settings.isComplete else { return }
        let partial = model.settings.printers.first { !$0.serial.isEmpty }
        show(model: model, mode: partial.map { .edit(serial: $0.serial) } ?? .add)
    }

    /// An open window comes to the front as it is, so a pending connect is never dropped.
    static func show(model: GlanceModel, mode: Mode) {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            let flow = SetupFlow(mode: mode, saved: model.settings, model: model)
            flow.dismiss = { [weak window] in window?.close() }
            self.flow = flow
            window.title = flow.title
            window.contentViewController = NSHostingController(rootView: SetupView(flow: flow))
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow() -> NSWindow {
        let window = SetupNSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        return window
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        /// The close button, Esc, and ⌘W all cancel.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            MainActor.assumeIsolated { SetupWindow.flow?.cancel() }
            return true
        }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                SetupWindow.flow?.didClose()
                SetupWindow.flow = nil
            }
        }
    }
}

/// Esc and ⌘W close like the close button, whatever has focus.
private final class SetupNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let esc = event.keyCode == 53 && mods.isEmpty
        let cmdW = mods == .command && event.charactersIgnoringModifiers == "w"
        if esc || cmdW {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SetupFlow: ObservableObject {
    let mode: SetupWindow.Mode
    let saved: SavedPrinters
    @Published var draft: PrinterSettings
    var dismiss: () -> Void = {}
    private weak var model: GlanceModel?

    /// `model` is nil when rendering in tests.
    init(mode: SetupWindow.Mode, saved: SavedPrinters, model: GlanceModel? = nil) {
        self.mode = mode
        self.saved = saved
        self.model = model
        if case let .edit(serial) = mode, let printer = saved.printers.first(where: { $0.serial == serial }) {
            draft = printer
        } else {
            draft = .empty
        }
        if case let .edit(serial) = mode {
            model?.setRediscoverPausedSerial(serial)
        }
    }

    var title: String {
        switch mode {
        case .add: return "Add Printer"
        case .edit: return "Edit \(draft.displayName)"
        }
    }

    var editingSerial: String? {
        if case let .edit(serial) = mode { return serial }
        return nil
    }

    func save() {
        if let serial = editingSerial {
            model?.updatePrinter(draft, serial: serial)
        } else {
            model?.addPrinter(draft)
        }
        dismiss()
    }

    func remove() {
        guard let serial = editingSerial else { return }
        model?.removePrinter(serial: serial)
        dismiss()
    }

    func cancel() {}

    func didClose() {
        model?.setRediscoverPausedSerial(nil)
    }
}

struct SetupView: View {
    @ObservedObject var flow: SetupFlow

    var body: some View {
        PrinterSettingsView(
            settings: $flow.draft,
            onSave: { _ in flow.save() },
            onRemove: flow.editingSerial != nil && flow.saved.printers.count > 1 ? { flow.remove() } : nil,
            onClose: { flow.dismiss() }
        )
    }
}
