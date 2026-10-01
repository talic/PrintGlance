import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GlanceView: View {
    @ObservedObject var model: GlanceModel
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var showPrinter = false
    @State private var showHistory = false
    @State private var draft = PrinterSettings.empty
    @State private var editingSerial: String?

    var body: some View {
        Group {
            if showHistory {
                HistoryView(
                    rows: model.historyRows,
                    onExport: exportHistory,
                    onClose: { showHistory = false }
                )
            } else if showPrinter {
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
                    onClose: { setPrinterForm(false) }
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
        .onAppear {
            if case .needsSetup = model.content.result {
                if let partial = model.settings.printers.first {
                    draft = partial
                    editingSerial = partial.serial.isEmpty ? nil : partial.serial
                    setPrinterForm(true)
                } else {
                    openAdd()
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            CardHeader(headline: headline, subtitle: subtitle, state: model.content.row?.state)
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
                PrinterDetail(
                    row: row,
                    endedAt: model.occupancyEndedAt,
                    now: model.occupancyNow,
                    disconnectReason: model.disconnectReason(for: row.id)
                )
            } else {
                emptyText
            }
        } else {
            emptyText
        }
    }

    private var emptyText: some View {
        Text(emptyDetail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

    private var overflowMenu: some View {
        Menu {
            if model.settings.canAdd {
                Button("Add Printer…") { openAdd() }
            }
            if let target = editTarget {
                Button("Edit \(target.displayName)…") { openEdit() }
            }
            Divider()
            Button("History") { showHistory = true }
            Menu("Notifications") {
                Toggle("Print Paused", isOn: $model.notifyPrefs.pause)
                Toggle("Print Failed", isOn: $model.notifyPrefs.fail)
                Toggle("Print Finished", isOn: $model.notifyPrefs.finish)
                Toggle("Print Finishing Soon", isOn: $model.notifyPrefs.comingOff)
                Toggle("Printer Went Offline", isOn: $model.notifyPrefs.offline)
                Divider()
                Toggle("Quiet Hours", isOn: $model.notifyPrefs.quietHours)
            }
            Toggle("Open at Login", isOn: $openAtLogin)
            Divider()
            Button("PrintGlance \(AppUpdate.bundledVersion)") {}
                .disabled(true)
            if let tag = model.availableUpdate {
                Button(GlanceContent.downloadTitle(tag: tag)) { model.openUpdatePage() }
            }
            Divider()
            Button("Quit PrintGlance") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
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

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "printglance-history.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.exportHistory(to: url)
        }
    }

    private func setPrinterForm(_ open: Bool) {
        showPrinter = open
        model.setRediscoverPausedSerial(open ? editingSerial : nil)
    }

    private func openAdd() {
        draft = .empty
        editingSerial = nil
        showHistory = false
        setPrinterForm(true)
    }

    private var editTarget: PrinterSettings? {
        model.settings.printers.first { $0.serial == model.settings.focusId }
            ?? model.content.row.flatMap { row in model.settings.printers.first { $0.serial == row.id } }
            ?? model.settings.printers.first
    }

    private func openEdit() {
        guard let target = editTarget else {
            openAdd()
            return
        }
        draft = target
        editingSerial = target.serial
        showHistory = false
        setPrinterForm(true)
    }

    private var headline: String {
        if let row = model.content.row {
            return GlanceContent.headline(row)
        }
        switch model.content.result {
        case .feedDown: return "Can't reach printer"
        case .needsSetup: return "Add your printer"
        case .connecting: return "Connecting"
        case .doc: return "No printer"
        }
    }

    private var subtitle: String? {
        model.content.row.map(GlanceContent.subtitle)
    }

    private var emptyDetail: String {
        switch model.content.result {
        case .feedDown:
            return GlanceCopy.feedDownDetail(reason: model.disconnectReason(for: model.settings.focusId))
        case .needsSetup:
            return "Click … and choose Add Printer. Enter the IP address, serial number, and access code from the printer's LAN or Network page."
        case .connecting:
            return "Connecting to the printer."
        case .doc:
            return "No printer"
        }
    }
}

struct CardHeader: View {
    var headline: String
    var subtitle: String?
    var state: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(stateColor(state, otherwise: .secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One printer's card body. Plain values in, so every state renders without a printer.
struct PrinterDetail: View {
    var row: Printer
    var endedAt: Date?
    var now: Date
    var disconnectReason: String?

    var body: some View {
        let timed = GlanceContent.isTimed(row.state)

        if timed {
            VStack(alignment: .leading, spacing: 2) {
                heroText(row)
                if let left = GlanceContent.remainingLine(row) {
                    Text(left)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let percent = row.percent {
                HStack(spacing: 8) {
                    CapsuleBar(percent: percent, tint: stateColor(row.state, otherwise: .primary))
                    Text("\(percent)%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }

            metaRow(row)
        } else if row.state.uppercased() == "FINISH" {
            VStack(alignment: .leading, spacing: 2) {
                heroText(row)
                if let caption = printerCaption(row) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            amsBlock(row)
        } else if row.state.uppercased() == "OFFLINE" {
            Text(GlanceCopy.feedDownDetail(reason: disconnectReason))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if let caption = printerCaption(row) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            amsBlock(row)
        }
    }

    private func heroText(_ row: Printer) -> some View {
        Text(GlanceContent.hero(
            row,
            occupancyEndedAt: endedAt,
            now: now
        ))
        .font(.system(size: 28, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private func amsBlock(_ row: Printer) -> some View {
        let idle = ["IDLE", "FINISH"].contains(row.state.uppercased())
        if idle, let trays = row.trays, !trays.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let h = row.humidity {
                    Text("Humidity \(h)/5")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(trays) { tray in
                    HStack(spacing: 6) {
                        if let hex = tray.color {
                            FilamentDot(hex: hex)
                        }
                        Text(amsLine(tray))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private func amsLine(_ tray: AMSTray) -> String {
        let name = tray.id == "ext"
            ? tray.name.map { "External · \($0)" } ?? "External"
            : tray.name ?? "Slot \(tray.id)"
        return tray.remain.map { "\(name)  \($0)%" } ?? name
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
                    HStack(spacing: 4) {
                        if let hex = row.filamentColor {
                            FilamentDot(hex: hex)
                        }
                        Text(fil)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private func stateColor(_ state: String?, otherwise: Color) -> Color {
    switch state?.uppercased() {
    case "PAUSE": return .orange
    case "FAILED": return .red
    default: return otherwise
    }
}

private extension Color {
    init?(filamentHex: String) {
        guard filamentHex.count == 8, let v = UInt32(filamentHex, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((v >> 24) & 0xFF) / 255,
            green: Double((v >> 16) & 0xFF) / 255,
            blue: Double((v >> 8) & 0xFF) / 255,
            opacity: Double(v & 0xFF) / 255
        )
    }
}

private struct FilamentDot: View {
    var hex: String

    var body: some View {
        if let c = Color(filamentHex: hex) {
            Circle()
                .fill(c)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle().stroke(Color.primary.opacity(0.3), lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        }
    }
}

struct HistoryView: View {
    var rows: [JobLogRow]
    var onExport: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Button("Export CSV", action: onExport)
                    .disabled(rows.isEmpty)
            }
            if rows.isEmpty {
                Text("No prints on this Mac yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        historyRow(row)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Back", action: onClose)
            }
        }
        .padding(14)
        .frame(width: 248, alignment: .leading)
    }

    private func historyRow(_ row: JobLogRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(historyTitle(row))
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(historyCaption(row))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func historyTitle(_ row: JobLogRow) -> String {
        if let job = row.job, !job.isEmpty { return job }
        return row.name
    }

    private func historyCaption(_ row: JobLogRow) -> String {
        var parts = [row.name]
        if let outcome = row.outcome {
            parts.append(outcome == JobLog.outcomeFail ? "Failed" : "Finished")
        } else {
            parts.append("Printing")
        }
        if let end = row.endedAt {
            let minutes = max(0, Int(end.timeIntervalSince(row.startAt) / 60))
            parts.append("\(minutes) min")
        }
        return parts.joined(separator: " · ")
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
