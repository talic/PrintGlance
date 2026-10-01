import SwiftUI

@MainActor
final class SetupFlow: ObservableObject {
    let mode: SetupWindow.Mode
    let saved: SavedPrinters
    @Published var draft: PrinterSettings
    @Published var found: [PrinterDiscovery.Hit] = []
    @Published var scanning = false
    /// "Enter IP and serial instead" is open.
    @Published var manual: Bool
    var dismiss: () -> Void = {}
    private weak var model: GlanceModel?
    private var scanTask: Task<Void, Never>?

    /// `model` is nil when rendering in tests.
    init(mode: SetupWindow.Mode, saved: SavedPrinters, model: GlanceModel? = nil) {
        self.mode = mode
        self.saved = saved
        self.model = model
        var draft = PrinterSettings.empty
        if case let .edit(serial) = mode {
            draft = saved.printers.first { $0.serial == serial } ?? draft
            model?.setRediscoverPausedSerial(serial)
        }
        self.draft = draft
        manual = mode != .add
    }

    var title: String {
        editingSerial == nil ? "Add Printer" : "Edit \(draft.displayName)"
    }

    var editingSerial: String? {
        if case let .edit(serial) = mode { return serial }
        return nil
    }

    func scan() {
        scanTask?.cancel()
        scanning = true
        found = []
        scanTask = Task { [weak self] in
            let hits = await PrinterDiscovery.scan()
            guard let self, !Task.isCancelled else { return }
            found = hits
            scanning = false
            if hits.isEmpty { manual = true }
        }
    }

    func pick(_ hit: PrinterDiscovery.Hit) {
        draft.ip = hit.ip
        draft.serial = hit.serial
        // Keep a name the user typed; replace one an earlier pick filled in.
        if draft.name.isEmpty || found.contains(where: { Self.suggestedName($0) == draft.name }) {
            draft.name = Self.suggestedName(hit)
        }
    }

    func isSelected(_ hit: PrinterDiscovery.Hit) -> Bool {
        !hit.serial.isEmpty && Self.sameSerial(hit.serial, draft.serial)
    }

    func isAdded(_ hit: PrinterDiscovery.Hit) -> Bool {
        Self.isAdded(hit, saved: saved, editing: editingSerial)
    }

    func connect() {
        if let serial = editingSerial {
            model?.updatePrinter(draft, serial: serial)
        } else {
            model?.addPrinter(draft)
        }
        dismiss()
    }

    func remove() {
        guard let serial = editingSerial, SetupWindow.confirmRemove(name: draft.displayName) else { return }
        model?.removePrinter(serial: serial)
        dismiss()
    }

    func cancel() {}

    func didClose() {
        scanTask?.cancel()
        model?.setRediscoverPausedSerial(nil)
    }

    /// Another saved printer, so picking it would replace that one. Serials match ignoring case, like `PrinterDiscovery.ipChanges`.
    nonisolated static func isAdded(_ hit: PrinterDiscovery.Hit, saved: SavedPrinters, editing: String?) -> Bool {
        guard !hit.serial.isEmpty, editing.map({ sameSerial($0, hit.serial) }) != true else { return false }
        return saved.printers.contains { $0.isComplete && sameSerial($0.serial, hit.serial) }
    }

    /// The printer's own name, else its model.
    nonisolated static func suggestedName(_ hit: PrinterDiscovery.Hit) -> String {
        hit.name.isEmpty ? PrinterDiscovery.modelName(hit.model) : hit.name
    }

    nonisolated static func codeHint(_ code: String) -> String? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty || code.count == 8 ? nil : "Access codes are usually 8 characters."
    }

    nonisolated private static func sameSerial(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}

struct SetupView: View {
    @ObservedObject var flow: SetupFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pick your printer, then enter its access code. On the printer, open Settings, then LAN or Network.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            foundList
            fields
            buttons
        }
        .padding(20)
        .frame(width: 360)
    }

    private var foundList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Printers on this Wi-Fi")
                    .fontWeight(.medium)
                Spacer()
                if flow.scanning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Search Again") { flow.scan() }
                }
            }
            if !flow.found.isEmpty {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(flow.found.enumerated()), id: \.element.id) { i, hit in
                            if i > 0 { Divider() }
                            row(hit)
                        }
                    }
                }
            } else if !flow.scanning {
                Text("No printers found on this Wi-Fi.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ hit: PrinterDiscovery.Hit) -> some View {
        let added = flow.isAdded(hit)
        let selected = flow.isSelected(hit)
        let name = SetupFlow.suggestedName(hit)
        let model = hit.name.isEmpty ? "" : PrinterDiscovery.modelName(hit.model)
        return Button {
            flow.pick(hit)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name.isEmpty ? hit.ip : name)
                    Text([model, hit.ip].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if added {
                    Text("Added")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Enter IP and serial instead", isExpanded: $flow.manual) {
                VStack(alignment: .leading, spacing: 8) {
                    field("IP address", $flow.draft.ip)
                    field("Serial number", $flow.draft.serial)
                }
                .padding(.top, 4)
            }
            field("Access code", $flow.draft.accessCode, monospaced: true)
            if let hint = SetupFlow.codeHint(flow.draft.accessCode) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Self.labelWidth + 8)
            }
            field("Name", $flow.draft.name, prompt: "Optional")
        }
    }

    private static let labelWidth: CGFloat = 96

    private func field(
        _ title: String,
        _ text: Binding<String>,
        prompt: String? = nil,
        monospaced: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: Self.labelWidth, alignment: .trailing)
                .accessibilityHidden(true)
            TextField(title, text: text, prompt: Text(prompt ?? ""))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .body.monospaced() : .body)
                .autocorrectionDisabled()
        }
    }

    private var buttons: some View {
        HStack {
            if flow.editingSerial != nil {
                Button("Remove…", role: .destructive) { flow.remove() }
            }
            Spacer()
            Button("Cancel") {
                flow.cancel()
                flow.dismiss()
            }
            Button(flow.editingSerial == nil ? "Connect" : "Save") { flow.connect() }
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.draft.trimmed.isComplete)
        }
    }
}
