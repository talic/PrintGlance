import SwiftUI
import WidgetKit

@main
struct PrintGlancePhone: App {
    var body: some Scene {
        WindowGroup { PhoneScreen() }
    }
}

/// The printers, what each last said, and how to add the widget. **+** opens the Add Printer sheet, and
/// tapping a card opens its Edit sheet. Asking the printers here also gets the Local Network prompt out of
/// the way, which the widget can't show.
struct PhoneScreen: View {
    private enum Sheet: Identifiable {
        case add
        /// The saved printer with this serial.
        case edit(String)

        var id: String {
            switch self {
            case .add: "add"
            case let .edit(serial): "edit \(serial)"
            }
        }
    }

    private let store = PhoneStore.shared
    @State private var printers: [PrinterSettings] = []
    @State private var statuses: [PhoneStatus] = []
    /// Why each printer didn't answer the last look, by serial.
    @State private var failures: [String: String] = [:]
    @State private var refreshing = false
    @State private var sheet: Sheet?
    /// The Add Printer sheet's entries.
    @State private var form = PrinterSettings.empty
    /// The Edit sheet's entries.
    @State private var draft = PrinterSettings.empty
    /// Nil until the first search ends.
    @State private var found: [PrinterSettings]?
    @State private var searching = false
    @State private var connecting = false
    @State private var connectTask: Task<Void, Never>?
    @State private var confirmingRemove = false
    @State private var alert: PhoneAlert?
    /// An alert inside the open sheet, which covers this screen's.
    @State private var sheetAlert: PhoneAlert?
    /// Shown once the sheet has gone, so the two presentations don't collide.
    @State private var alertAfterSheet: PhoneAlert?
    /// Asked once the Edit sheet has gone, with what was saved.
    @State private var askAfterSheet: PrinterSettings?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            Form {
                if store == nil {
                    Section {
                        Text("The widget can't read what this app saves. In Xcode, give both targets the App Group \(PhoneStore.appGroup ?? "in PGAppGroup"), then build again.")
                    }
                }
                if printers.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Printers", systemImage: "printer")
                        } description: {
                            Text("Add your printer to see its progress here and in the widget.")
                        } actions: {
                            Button("Add Printer") { add() }
                                .buttonStyle(.borderedProminent)
                                .disabled(store == nil)
                        }
                    }
                } else {
                    Section {
                        ForEach(printers, id: \.serial) { printer in
                            Button { edit(printer) } label: { card(printer) }
                                .tint(.primary)
                                .accessibilityHint("Change or remove this printer.")
                                .swipeActions {
                                    Button("Remove", role: .destructive) { remove(printer.serial) }
                                }
                        }
                    } header: {
                        Text("Your printers")
                    } footer: {
                        Text("Tap a printer to change or remove it.")
                    }
                }
                Section("Widget") {
                    Text("Touch and hold the Home Screen or Lock Screen, tap Edit, then Add Widget, and choose PrintGlance. It shows the printer that needs you. The medium size shows two. It updates about every 15 minutes while this iPhone is on the printers' Wi-Fi.")
                }
            }
            .navigationTitle("PrintGlance")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { add() } label: { Label("Add Printer", systemImage: "plus") }
                        .disabled(store == nil)
                }
            }
            .refreshable { await refresh() }
            .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button("OK") {}
            } message: {
                Text(alert?.message ?? "")
            }
        }
        .sheet(item: $sheet, onDismiss: { sheetClosed() }) { sheet in
            switch sheet {
            case .add: addSheet
            case let .edit(serial): editSheet(serial)
            }
        }
        .onAppear {
            load()
            if printers.isEmpty, store != nil { add() }
        }
        .onChange(of: phase) {
            guard phase == .active else { return }
            Task { await refresh() }
            // The first search runs under iOS's Local Network question and finds nothing until it is
            // answered; answering makes the app active again, so look once more while adding.
            if case .add? = sheet, found?.isEmpty == true { Task { await search() } }
        }
    }

    // MARK: Screens

    private func card(_ printer: PrinterSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PhoneCard(lines: GlanceContent.phone(status(printer), printer: printer, now: Date()), showsExtra: true)
            if let failure = failures[printer.serial] {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The printer (picked from the search or typed), then its access code, then a name, like the Mac.
    private var addSheet: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        if searching {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Searching…")
                            }
                        } else if found?.isEmpty == true {
                            Text("No printers found on this Wi-Fi.")
                        }
                        ForEach(GlanceContent.phoneHits(found ?? [], saved: printers, form: form), id: \.serial) { hit in
                            hitRow(hit)
                        }
                        Button(found == nil ? "Search for Printers" : "Search Again") { Task { await search() } }
                            .disabled(searching)
                    } header: {
                        Text("Printers on this Wi-Fi")
                    } footer: {
                        Text("A printer you haven't added shows its serial number. On the printer screen, open Settings and look on the LAN or Network page or in device info. It's also on the sticker on the printer.")
                    }
                    Section {
                        field("IP address", $form.ip)
                            .keyboardType(.numbersAndPunctuation)
                        field("Serial number", $form.serial)
                            .textInputAutocapitalization(.characters)
                    } header: {
                        Text("Printer")
                    } footer: {
                        if let added = GlanceContent.phoneAlreadyAdded(form, saved: printers) {
                            Text(added)
                        }
                    }
                    codeSection($form.accessCode)
                    Section {
                        field("Name", $form.name, prompt: "Optional")
                    }
                }
                .disabled(connecting)
            }
            .navigationTitle("Add Printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(connecting ? "Connecting…" : "Connect") { connect() }
                        .disabled(
                            connecting || !form.trimmed.isComplete
                                || GlanceContent.phoneAlreadyAdded(form, saved: printers) != nil
                        )
                }
            }
            .alert(
                sheetAlert?.title ?? "",
                isPresented: Binding(get: { sheetAlert != nil }, set: { if !$0 { sheetAlert = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(sheetAlert?.message ?? "")
            }
        }
    }

    private func hitRow(_ hit: PhoneHit) -> some View {
        Button {
            form = form.picking(PrinterSettings(ip: hit.ip, serial: hit.serial, accessCode: "", name: ""), saved: printers)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title)
                    Text(hit.ip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hit.added {
                    Text("Added")
                        .foregroundStyle(.secondary)
                } else if hit.picked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .tint(.primary)
        .disabled(hit.added)
        .accessibilityAddTraits(hit.picked ? .isSelected : [])
    }

    /// The serial stays as it is: it's what the printer answers to.
    @ViewBuilder
    private func editSheet(_ serial: String) -> some View {
        let name = printers.first { $0.serial == serial }?.displayName ?? draft.displayName
        let removal = GlanceCopy.phoneRemove(name: name)
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Serial number", value: serial)
                    field("IP address", $draft.ip)
                        .keyboardType(.numbersAndPunctuation)
                }
                codeSection($draft.accessCode)
                Section {
                    field("Name", $draft.name, prompt: "Optional")
                }
                Section {
                    Button("Remove Printer", role: .destructive) { confirmingRemove = true }
                }
            }
            .navigationTitle("Edit \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(serial) }
                        .disabled(!draft.trimmed.isComplete)
                }
            }
            .confirmationDialog(removal.title, isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove Printer", role: .destructive) {
                    remove(serial)
                    sheet = nil
                }
            } message: {
                Text(removal.message)
            }
        }
    }

    /// Monospaced and as typed, like the Mac: people copy it off the printer's screen.
    private func codeSection(_ code: Binding<String>) -> some View {
        Section {
            LabeledContent("Access code") {
                TextField("Access code", text: code)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospaced())
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let hint = PrinterSettings.codeHint(code.wrappedValue) {
                    Text(hint)
                }
                Text("On the printer screen, open Settings, then the LAN or Network page.")
            }
        }
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String? = nil) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt ?? ""))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
        }
    }

    // MARK: Actions

    private func status(_ printer: PrinterSettings) -> PhoneStatus? {
        statuses.first { $0.printer.id == printer.serial }
    }

    private func load() {
        printers = store?.printers ?? []
        statuses = store?.statuses ?? []
    }

    /// Opens the Add Printer sheet and searches, or says four is the limit.
    private func add() {
        guard SavedPrinters(printers: printers, focusId: nil).canAdd else {
            alert = GlanceCopy.phoneTooMany()
            return
        }
        form = .empty
        sheet = .add
        Task { await search() }
    }

    private func edit(_ printer: PrinterSettings) {
        draft = printer
        sheet = .edit(printer.serial)
    }

    /// Asks the printer in the form, and adds it only once it answers, like the Mac's Add Printer window.
    /// If it doesn't, the sheet stays open with what was typed and says why.
    private func connect() {
        guard let store else { return }
        let printer = form.trimmed
        guard SavedPrinters(printers: printers, focusId: nil).adding(printer).printers.contains(where: { $0.serial == printer.serial })
        else {
            sheetAlert = GlanceCopy.phoneTooMany()
            return
        }
        connecting = true
        connectTask = Task {
            let outcome = await PrinterFetch.fetch(printer)
            // Cancel or a swipe down while it asked: add nothing.
            guard !Task.isCancelled else { return }
            connecting = false
            guard case .printer = outcome else {
                sheetAlert = GlanceCopy.phoneConnected(outcome, name: printer.displayName)
                return
            }
            store.save(SavedPrinters(printers: store.printers, focusId: nil).adding(printer).printers)
            store.record([printer.serial: outcome], at: Date())
            failures[printer.serial] = nil
            load()
            WidgetCenter.shared.reloadAllTimelines()
            alertAfterSheet = GlanceCopy.phoneConnected(outcome, name: printer.displayName)
            sheet = nil
        }
    }

    /// Saves at once, so a printer that's off can still be renamed, then asks it once the sheet has gone.
    private func save(_ serial: String) {
        guard let store else { return }
        let printer = draft.trimmed
        store.save(SavedPrinters(printers: printers, focusId: nil).replacing(printer, serial: serial).printers)
        load()
        askAfterSheet = printer
        sheet = nil
    }

    private func remove(_ serial: String) {
        store?.save(printers.filter { $0.serial != serial })
        failures[serial] = nil
        load()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Cancel, a swipe down, or a finished Connect or Save.
    private func sheetClosed() {
        connectTask?.cancel()
        connectTask = nil
        connecting = false
        if let next = alertAfterSheet {
            alertAfterSheet = nil
            alert = next
        }
        if let printer = askAfterSheet {
            askAfterSheet = nil
            Task {
                let outcomes = await ask([printer])
                if let outcome = outcomes[printer.serial], let saved = GlanceCopy.phoneSaved(outcome, name: printer.displayName) {
                    alert = saved
                }
            }
        }
    }

    /// One printer found that isn't saved yet, and no IP or serial typed: fill them in.
    private func search() async {
        guard !searching else { return }
        searching = true
        let hits = await PrinterSearch.scan()
        found = hits
        searching = false
        form = form.autoPicking(from: hits, saved: printers)
    }

    /// Pull to refresh and coming to the front: every printer at once.
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await ask(printers)
    }

    /// Asks these saved printers at once and keeps what they said, or why they didn't answer.
    @discardableResult
    private func ask(_ targets: [PrinterSettings]) async -> [String: PrinterFetch.Outcome] {
        guard let store, !targets.isEmpty else { return [:] }
        let outcomes = await PrinterFetch.fetchAll(targets)
        store.record(outcomes, at: Date())
        statuses = store.statuses
        for (serial, outcome) in outcomes {
            if case let .failed(reason) = outcome {
                failures[serial] = GlanceCopy.phoneFetchFailed(reason: reason)
            } else {
                failures[serial] = nil
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        return outcomes
    }
}
