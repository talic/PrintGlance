import Combine
import SwiftUI

@MainActor
final class SetupFlow: ObservableObject {
    enum Phase: Equatable {
        case form
        case connecting
        case failed(String)
        case connected
        /// After the first printer connects.
        case welcome
    }

    enum ConnectResult: Equatable {
        case waiting
        case connected
        case failed(String)
    }

    /// Links retry with backoff, so stop waiting and say why.
    static let connectWait: Duration = .seconds(20)

    let mode: SetupWindow.Mode
    let saved: SavedPrinters
    @Published var draft: PrinterSettings
    @Published var found: [PrinterDiscovery.Hit] = []
    @Published var scanning = false
    /// "Enter IP and serial instead" is open.
    @Published var manual: Bool
    @Published var phase = Phase.form
    @Published var openAtLogin = true
    @Published var loginNeedsApproval = false
    var dismiss: () -> Void = {}
    private weak var model: GlanceModel?
    private let discover: @Sendable () async -> [PrinterDiscovery.Hit]
    private var scanTask: Task<Void, Never>?
    /// The printers before the first Connect. Cancel puts them back.
    private var original: SavedPrinters?
    private var watch: AnyCancellable?
    private var deadline: Task<Void, Never>?

    /// `model` is nil when rendering in tests.
    init(
        mode: SetupWindow.Mode,
        saved: SavedPrinters,
        model: GlanceModel? = nil,
        discover: @escaping @Sendable () async -> [PrinterDiscovery.Hit] = { await PrinterDiscovery.scan() }
    ) {
        self.mode = mode
        self.saved = saved
        self.model = model
        self.discover = discover
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
        scanTask = Task { [weak self, discover] in
            let hits = await discover()
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

    /// Saves, then waits for the real connection. Each try starts from the printers before the first one.
    func connect() {
        guard let model else { return }
        let base = original ?? model.settings
        original = base
        let printer = draft.trimmed
        model.saveSettings(editingSerial.map { base.replacing(printer, serial: $0) } ?? base.adding(printer))
        phase = .connecting
        let serial = printer.serial
        let ip = printer.ip
        // A sink, not `.values`: an async sequence drops changes that land while it is busy.
        watch = model.$linkStatus
            .map { $0[serial] }
            .removeDuplicates()
            .sink { [weak self] status in self?.observe(Self.connectResult(status, ip: ip)) }
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.connectWait)
            guard !Task.isCancelled else { return }
            self?.observe(.failed(Self.failureMessage(nil, ip: ip)))
        }
    }

    /// A failure only ends a wait. A later success still counts: rediscovery may find the printer at a new IP.
    private func observe(_ result: ConnectResult) {
        switch result {
        case .waiting:
            break
        case let .failed(message):
            if phase == .connecting { phase = .failed(message) }
        case .connected:
            switch phase {
            case .connecting, .failed: break
            case .form, .connected, .welcome: return
            }
            stopWaiting()
            if original?.isComplete == false {
                phase = .welcome
            } else {
                phase = .connected
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.dismiss()
                }
            }
        }
    }

    func remove() {
        guard let serial = editingSerial, let model, SetupWindow.confirmRemove(name: draft.displayName) else { return }
        model.saveSettings((original ?? model.settings).removing(serial: serial))
        dismiss()
    }

    /// Done on the welcome step. Pass `closing` when the window is already going away.
    func finish(closing: Bool = false) {
        if !loginNeedsApproval {
            LoginItem.setEnabled(openAtLogin)
            if openAtLogin, LoginItem.needsApproval, !closing {
                loginNeedsApproval = true
                return
            }
        }
        model?.requestNotificationPermission()
        if !closing { dismiss() }
    }

    /// The Cancel button, the close button, Esc, and ⌘W.
    func cancel() {
        switch phase {
        case .welcome:
            finish(closing: true)
        case .connected:
            break
        case .form, .connecting, .failed:
            if let original, let model, model.settings != original {
                model.saveSettings(original)
            }
        }
    }

    func didClose() {
        scanTask?.cancel()
        stopWaiting()
        model?.setRediscoverPausedSerial(nil)
    }

    private func stopWaiting() {
        watch = nil
        deadline?.cancel()
    }

    nonisolated static func connectResult(_ status: LinkStatus?, ip: String) -> ConnectResult {
        switch status {
        case .connected: return .connected
        case let .failed(reason): return .failed(failureMessage(reason, ip: ip))
        case .connecting, nil: return .waiting
        }
    }

    nonisolated static func failureMessage(_ reason: String?, ip: String) -> String {
        if GlanceCopy.codeRejected(reason) {
            return "The access code was rejected. Check it on the printer: Settings, then LAN or Network."
        }
        if reason?.contains("ECONNREFUSED") == true {
            return GlanceCopy.feedDownDetail(reason: reason)
        }
        return "No answer from \(ip). Check that the printer is on and on the same Wi-Fi as this Mac."
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
        Group {
            if flow.phase == .welcome {
                welcome
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pick your printer, then enter its access code. On the printer, open Settings, then LAN or Network.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        foundList
                        fields
                    }
                    .disabled(flow.phase == .connecting)
                    status
                    buttons
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private var status: some View {
        switch flow.phase {
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                let name = flow.draft.trimmed.name
                Text(name.isEmpty ? "Connecting to the printer…" : "Connecting to \(name)…")
            }
        case let .failed(message):
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
        case .connected:
            connectedLabel
        case .form, .welcome:
            EmptyView()
        }
    }

    private var connectedLabel: some View {
        Label {
            Text("Connected")
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectedLabel
                .font(.headline)
            Text("PrintGlance is in your menu bar. Click it to see your print.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open at login", isOn: $flow.openAtLogin)
                .disabled(flow.loginNeedsApproval)
            if flow.loginNeedsApproval {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow PrintGlance in System Settings > General > Login Items.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { LoginItem.openSettings() }
                }
            }
            HStack {
                Spacer()
                Button("Done") { flow.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
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
                    .disabled(flow.phase == .connecting)
            }
            Spacer()
            Button("Cancel") {
                flow.cancel()
                flow.dismiss()
            }
            Button(defaultTitle) { flow.connect() }
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.draft.trimmed.isComplete || flow.phase == .connecting || flow.phase == .connected)
        }
    }

    private var defaultTitle: String {
        if case .failed = flow.phase { return "Try Again" }
        return flow.editingSerial == nil ? "Connect" : "Save"
    }
}
