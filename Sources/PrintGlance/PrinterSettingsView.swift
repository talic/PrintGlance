import SwiftUI

struct PrinterSettingsView: View {
    @Binding var settings: PrinterSettings
    var onSave: (PrinterSettings) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Printer")
                .font(.headline)
            Text("On the printer, open Settings, then LAN or Network. Copy the IP address, access code, and serial number. You do not need LAN Only mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
    }
}
