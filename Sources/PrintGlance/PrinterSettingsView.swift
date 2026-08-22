import SwiftUI

struct PrinterSettingsView: View {
    @Binding var settings: PrinterSettings
    var onSave: (PrinterSettings) -> Void
    var onClose: () -> Void

    @State private var scanning = false
    @State private var found: [PrinterDiscovery.Hit] = []
    @State private var scanNote: String?
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Printer")
                .font(.headline)
            Text("On the printer, open Settings, then LAN or Network. Pick a printer found on this Wi-Fi, or enter the IP address and serial number. You still enter the access code. PrintGlance only reads status on your Wi-Fi. It does not pause, stop, or start a print.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(scanning ? "Looking for printers" : "Find printers") {
                scanTask?.cancel()
                scanTask = Task { await runScan() }
            }
            .disabled(scanning)

            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(found) { hit in
                        Button {
                            apply(hit)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.name.isEmpty ? hit.ip : hit.name)
                                    .foregroundStyle(.primary)
                                Text(detail(hit))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let scanNote {
                Text(scanNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("IP address", text: $settings.ip)
            field("Serial number", text: $settings.serial)
            SecureField("Access code", text: $settings.accessCode)
                .textFieldStyle(.roundedBorder)
            field("Name (optional)", text: $settings.name)

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("Save") {
                    onSave(settings.trimmed)
                    onClose()
                }
                .disabled(!settings.trimmed.isComplete)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            scanTask = Task { await runScan() }
        }
        .onDisappear {
            scanTask?.cancel()
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
    }

    private func detail(_ hit: PrinterDiscovery.Hit) -> String {
        [hit.ip, hit.serial].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func apply(_ hit: PrinterDiscovery.Hit) {
        settings.ip = hit.ip
        if !hit.serial.isEmpty { settings.serial = hit.serial }
        if !hit.name.isEmpty { settings.name = hit.name }
    }

    @MainActor
    private func runScan() async {
        scanning = true
        scanNote = nil
        let hits = await PrinterDiscovery.scan()
        guard !Task.isCancelled else { return }
        found = hits
        scanning = false
        if hits.isEmpty {
            scanNote = "No printers found on this Wi-Fi. Enter the IP address, serial number, and access code from the printer."
        }
    }
}
