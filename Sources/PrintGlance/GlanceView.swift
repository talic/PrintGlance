import AppKit
import SwiftUI

struct GlanceView: View {
    @ObservedObject var model: GlanceModel
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var showPrinter = false
    @State private var draft = PrinterSettings.empty
    @State private var editingSerial: String?

    var body: some View {
        Group {
            if showPrinter {
                PrinterSettingsView(
                    title: editingSerial == nil ? "Add printer" : "Printer",
                    settings: $draft,
                    onSave: { saved in
                        if let serial = editingSerial {
                            model.updatePrinter(saved, serial: serial)
                        } else {
                            model.addPrinter(saved)
                        }
                    },
                    onRemove: removeAction,
                    onClose: { showPrinter = false }
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    bodyContent
                    if model.availableUpdate != nil {
                        Button("Update available") {
                            model.openUpdatePage()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Download PrintGlance update")
                    }
                }
                .padding(14)
                .frame(width: 248, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if case .needsSetup = model.content.result {
                if let partial = model.settings.printers.first {
                    draft = partial
                    editingSerial = partial.serial.isEmpty ? nil : partial.serial
                    showPrinter = true
                } else {
                    openAdd()
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let sub = subtitle {
                    Text(sub)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            overflowMenu
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if case let .doc(doc) = model.content.result {
            if doc.printers.count > 1 {
                fleetList(doc)
            }
            if let row = doc.focusRow() {
                printerBody(row)
            } else {
                Text(emptyDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(emptyDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fleetList(_ doc: PrintDoc) -> some View {
        let focused = doc.focusRow()?.id
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(doc.printers, id: \.id) { p in
                Button {
                    model.focusPrinter(p.id)
                } label: {
                    HStack(spacing: 6) {
                        Text(p.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let pct = p.percent, GlanceContent.isTimed(p.state) {
                            Text("\(pct)%")
                                .monospacedDigit()
                        }
                        Text(GlanceContent.humanState(p.state))
                    }
                    .font(.caption)
                    .foregroundStyle(p.id == focused ? .primary : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(listA11y(p, focused: p.id == focused))
            }
        }
    }

    private func listA11y(_ row: Printer, focused: Bool) -> String {
        var parts = [row.name, GlanceContent.humanState(row.state)]
        if let pct = row.percent, GlanceContent.isTimed(row.state) {
            parts.append("\(pct) percent")
        }
        if focused {
            parts.append("focused")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func printerBody(_ row: Printer) -> some View {
        let timed = GlanceContent.isTimed(row.state)

        if timed {
            VStack(alignment: .leading, spacing: 2) {
                Text(GlanceContent.hero(row))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let left = GlanceContent.remainingLine(row) {
                    Text(left)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let percent = row.percent {
                HStack(spacing: 8) {
                    CapsuleBar(percent: percent, tint: barTint(row.state))
                    Text("\(percent)%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }

            metaRow(row)
        } else if let caption = printerCaption(row) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var overflowMenu: some View {
        Menu {
            if model.settings.canAdd {
                Button("Add printer") { openAdd() }
            }
            if !model.settings.printers.isEmpty {
                Button("Printer") { openEdit() }
            }
            Menu("Notifications") {
                Toggle("Print finished", isOn: $model.notifyPrefs.finish)
                Toggle("Print failed", isOn: $model.notifyPrefs.fail)
                Toggle("Print paused", isOn: $model.notifyPrefs.pause)
                Toggle("Printer went offline", isOn: $model.notifyPrefs.offline)
            }
            Toggle("Open at Login", isOn: $openAtLogin)
            if model.availableUpdate != nil {
                Button("Download update") { model.openUpdatePage() }
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .onChange(of: openAtLogin) { _, on in
            LoginItem.setEnabled(on)
            openAtLogin = LoginItem.isEnabled
        }
    }

    private var removeAction: (() -> Void)? {
        guard editingSerial != nil, model.settings.printers.count > 1 else { return nil }
        return {
            if let serial = editingSerial {
                model.removePrinter(serial: serial)
            }
        }
    }

    private func openAdd() {
        draft = .empty
        editingSerial = nil
        showPrinter = true
    }

    private func openEdit() {
        let focused = model.settings.printers.first { $0.serial == model.settings.focusId }
            ?? model.content.row.flatMap { row in model.settings.printers.first { $0.serial == row.id } }
            ?? model.settings.printers.first
        guard let focused else {
            openAdd()
            return
        }
        draft = focused
        editingSerial = focused.serial
        showPrinter = true
    }

    private var headline: String {
        if let row = model.content.row, case .doc = model.content.result {
            if let job = row.job, !job.isEmpty { return job }
            return row.name
        }
        switch model.content.result {
        case .feedDown: return "Can't update"
        case .unauthorized: return "Can't update"
        case .http: return "Can't update"
        case .invalid: return "Can't update"
        case .needsSetup: return "Add your printer"
        case .connecting: return "Connecting"
        case .doc: return "No printer"
        }
    }

    private var subtitle: String? {
        if let row = model.content.row, case .doc = model.content.result {
            return GlanceContent.humanState(row.state)
        }
        return nil
    }

    private var emptyDetail: String {
        switch model.content.result {
        case .feedDown:
            return "Can't reach the printer. Check Wi-Fi, the IP address, and the access code."
        case .unauthorized:
            return "This Mac needs the feed token."
        case let .http(code):
            return "The feed returned HTTP \(code)."
        case .invalid:
            return "Can't read the feed."
        case .needsSetup:
            return "Click … and choose Add printer. Enter the IP address, serial number, and access code from the printer's LAN or Network page."
        case .connecting:
            return "Connecting to the printer."
        case .doc:
            return "The feed has no printer."
        }
    }

    private var statusColor: Color {
        guard let row = model.content.row, case .doc = model.content.result else {
            return .secondary
        }
        switch row.state.uppercased() {
        case "PAUSE": return .orange
        case "FAILED": return .red
        default: return .secondary
        }
    }

    private func barTint(_ state: String) -> Color {
        switch state.uppercased() {
        case "PAUSE": return .orange
        case "FAILED": return .red
        default: return .primary
        }
    }

    private func printerCaption(_ row: Printer) -> String? {
        if let job = row.job, !job.isEmpty { return row.name }
        return nil
    }

    @ViewBuilder
    private func metaRow(_ row: Printer) -> some View {
        let layer = GlanceContent.layerLine(row)
        let fil = GlanceContent.filamentLine(row)
        if layer != nil || fil != nil {
            HStack(alignment: .firstTextBaseline) {
                if let layer {
                    Text(layer).monospacedDigit()
                }
                Spacer(minLength: 8)
                if let fil {
                    Text(fil).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }
}

struct CapsuleBar: View {
    var percent: Int
    var tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, g.size.width * CGFloat(min(max(percent, 0), 100)) / 100))
            }
        }
        .frame(height: 4)
        .transaction { $0.animation = nil }
    }
}

struct StripLabel: View {
    var strip: StripPresentation

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: strip.systemImage)
            if !strip.title.isEmpty {
                Text(strip.title).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strip.accessibilityLabel)
    }
}
