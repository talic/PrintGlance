import SwiftUI
import WidgetKit

@main
struct PrintGlancePhone: App {
    var body: some Scene {
        WindowGroup { PhoneScreen() }
    }
}

/// The printer, what it last said, and how to add the widget. Asking the printer here also gets the
/// Local Network prompt out of the way, which the widget can't show.
struct PhoneScreen: View {
    private let store = PhoneStore.shared
    @State private var form = PrinterSettings.empty
    @State private var saved: PrinterSettings?
    @State private var status: PhoneStatus?
    @State private var failure: String?
    @State private var busy = false
    /// Nil until the first search ends.
    @State private var found: [PrinterSettings]?
    @State private var searching = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            Form {
                if store == nil {
                    Section {
                        Text("The widget can't read what this app saves. In Xcode, give both targets the App Group \(PhoneStore.appGroup ?? "in PGAppGroup"), then build again.")
                    }
                }
                if saved != nil {
                    Section {
                        PhoneCard(lines: GlanceContent.phone(status, hasPrinter: true, now: Date()), showsExtra: true)
                            .padding(.vertical, 4)
                    } footer: {
                        if let failure { Text(failure) }
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
                            form.ip = hit.ip
                            form.serial = hit.serial
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
                    Text("Tap your printer, then enter its access code below.")
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
                    Button(busy ? "Connecting…" : "Connect") {
                        store?.save(form)
                        saved = store?.printer
                        status = store?.status
                        Task { await refresh() }
                    }
                    .disabled(busy || store == nil || !form.trimmed.isComplete)
                }
                Section("Widget") {
                    Text("Touch and hold the Home Screen or Lock Screen, tap Edit, then Add Widget, and choose PrintGlance. It updates about every 15 minutes while this iPhone is on the printer's Wi-Fi.")
                }
            }
            .navigationTitle("PrintGlance")
            .refreshable { await refresh() }
        }
        .onAppear {
            saved = store?.printer
            form = saved ?? .empty
            status = store?.status
            if saved == nil { Task { await search() } }
        }
        .onChange(of: phase) {
            if phase == .active { Task { await refresh() } }
        }
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String? = nil) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt ?? ""))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
        }
    }

    /// One printer found and nothing typed yet: fill it in.
    private func search() async {
        guard !searching else { return }
        searching = true
        let hits = await PrinterSearch.scan()
        found = hits
        searching = false
        if hits.count == 1, form.trimmed.serial.isEmpty, let hit = hits.first {
            form.ip = hit.ip
            form.serial = hit.serial
        }
    }

    private func refresh() async {
        guard let store, let printer = store.printer, !busy else { return }
        busy = true
        defer { busy = false }
        switch await PrinterFetch.fetch(printer) {
        case let .printer(row):
            let fresh = PhoneStatus(printer: row, at: Date())
            store.save(fresh)
            status = fresh
            failure = nil
        case let .failed(reason):
            failure = GlanceCopy.phoneFetchFailed(reason: reason)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
