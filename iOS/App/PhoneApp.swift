import SwiftUI
import WidgetKit

@main
struct PrintGlancePhone: App {
    var body: some Scene {
        WindowGroup { PhoneScreen() }
    }
}

/// The printers, what each last said, and how to add the widget. Asking the printers here also gets the
/// Local Network prompt out of the way, which the widget can't show.
struct PhoneScreen: View {
    private let store = PhoneStore.shared
    @State private var form = PrinterSettings.empty
    @State private var printers: [PrinterSettings] = []
    @State private var statuses: [PhoneStatus] = []
    /// Why each printer didn't answer the last look, by serial.
    @State private var failures: [String: String] = [:]
    @State private var busy = false
    /// Nil until the first search ends.
    @State private var found: [PrinterSettings]?
    @State private var searching = false
    @State private var alert: PhoneAlert?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            Form {
                if store == nil {
                    Section {
                        Text("The widget can't read what this app saves. In Xcode, give both targets the App Group \(PhoneStore.appGroup ?? "in PGAppGroup"), then build again.")
                    }
                }
                if !printers.isEmpty {
                    Section {
                        ForEach(printers, id: \.serial) { printer in
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
                            .onTapGesture { form = printer }
                            .swipeActions {
                                Button("Remove", role: .destructive) { remove(printer) }
                            }
                        }
                    } header: {
                        Text("Your printers")
                    } footer: {
                        Text("Tap a printer to change its details. Swipe left to remove it.")
                    }
                }
                Section {
                    if searching {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Searching…")
                        }
                    } else if found?.isEmpty == true {
                        Text("No printers found on this Wi-Fi.")
                    }
                    ForEach(found ?? [], id: \.serial) { hit in
                        Button {
                            form = form.picking(hit, saved: printers)
                        } label: {
                            HStack {
                                LabeledContent(hit.serial, value: hit.ip)
                                if hit.serial == form.trimmed.serial {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                    Button(found == nil ? "Search for Printers" : "Search Again") { Task { await search() } }
                        .disabled(searching)
                } header: {
                    Text("Printers on this Wi-Fi")
                } footer: {
                    Text("Tap a printer, then enter its access code below.")
                }
                Section {
                    field("Name", $form.name, prompt: "Optional")
                    field("IP address", $form.ip)
                        .keyboardType(.numbersAndPunctuation)
                    field("Serial number", $form.serial)
                        .textInputAutocapitalization(.characters)
                    LabeledContent("Access code") {
                        SecureField("Access code", text: $form.accessCode)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Printer")
                } footer: {
                    Text("On the printer screen, open Settings, then the LAN or Network page. It shows the IP address and access code. The serial number is there, in device info, or on the sticker on the printer.")
                }
                Section {
                    Button(busy ? "Connecting…" : "Connect") { connect() }
                        .disabled(busy || store == nil || !form.trimmed.isComplete)
                }
                Section("Widget") {
                    Text("Touch and hold the Home Screen or Lock Screen, tap Edit, then Add Widget, and choose PrintGlance. It shows the printer that needs you. The medium size shows two. It updates about every 15 minutes while this iPhone is on the printers' Wi-Fi.")
                }
            }
            .navigationTitle("PrintGlance")
            .refreshable { await look(at: printers) }
            .alert(
                alert?.title ?? "",
                isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(alert?.message ?? "")
            }
        }
        .onAppear {
            load()
            if printers.isEmpty { Task { await search() } }
        }
        .onChange(of: phase) {
            guard phase == .active else { return }
            Task { await look(at: printers) }
            // The first search runs under iOS's Local Network question and finds nothing until it is
            // answered; answering makes the app active again, so look once more.
            if printers.isEmpty, found?.isEmpty == true { Task { await search() } }
        }
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String? = nil) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt ?? ""))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
        }
    }

    private func status(_ printer: PrinterSettings) -> PhoneStatus? {
        statuses.first { $0.printer.id == printer.serial }
    }

    private func load() {
        printers = store?.printers ?? []
        statuses = store?.statuses ?? []
    }

    /// Adds the printer in the form, or updates the saved one with its serial, then asks it.
    private func connect() {
        guard let store else { return }
        let printer = form.trimmed
        let next = SavedPrinters(printers: printers, focusId: nil).adding(printer)
        guard next.printers.contains(where: { $0.serial == printer.serial }) else {
            alert = GlanceCopy.phoneTooMany(name: printer.displayName)
            return
        }
        store.save(next.printers)
        load()
        Task { await look(at: [printer], announce: true) }
    }

    private func remove(_ printer: PrinterSettings) {
        store?.save(printers.filter { $0.serial != printer.serial })
        failures[printer.serial] = nil
        load()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// One printer found and nothing typed yet: fill it in.
    private func search() async {
        guard !searching else { return }
        searching = true
        let hits = await PrinterSearch.scan()
        found = hits
        searching = false
        if hits.count == 1, form.trimmed.serial.isEmpty, let hit = hits.first {
            form = form.picking(hit, saved: printers)
        }
    }

    /// Asks the printers at once. `announce`: after **Connect**, say how it went in an alert, not just in
    /// the printer's card.
    private func look(at targets: [PrinterSettings], announce: Bool = false) async {
        guard let store, !targets.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
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
        if announce, let printer = targets.first, let outcome = outcomes[printer.trimmed.serial] {
            alert = GlanceCopy.phoneConnected(outcome, name: printer.displayName)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
