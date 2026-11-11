import AppIntents
import SwiftUI
import WidgetKit

@main
struct PrintGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PrintGlance", intent: PrinterIntent.self, provider: Provider()) { entry in
            EntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("PrintGlance")
        .description("Your print's progress and finish time.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// Nothing to choose: the widget shows the printer that needs you. The async provider needs an intent.
struct PrinterIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "PrintGlance"
}

struct Entry: TimelineEntry {
    var date: Date
    /// Every printer's card, the one that needs you first.
    var cards: [PhoneLines]
}

/// Asks the printers each time iOS reloads the widget. Off their Wi-Fi the asks fail fast and the widget
/// keeps the last statuses, which the app also saves when it asks.
struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        let x2d = PrinterSettings(ip: "", serial: "", accessCode: "", name: "X2D")
        return Entry(date: Date(), cards: [GlanceContent.phone(PhoneStatus(printer: Self.sample, at: Date()), printer: x2d, now: Date())])
    }

    /// The gallery shows the sample until there is a real status; anywhere else, only what is true.
    func snapshot(for configuration: PrinterIntent, in context: Context) async -> Entry {
        let store = PhoneStore.shared
        let statuses = store?.statuses ?? []
        if context.isPreview, statuses.isEmpty { return placeholder(in: context) }
        return Entry(date: Date(), cards: GlanceContent.phoneCards(store?.printers ?? [], statuses: statuses, now: Date()))
    }

    func timeline(for configuration: PrinterIntent, in context: Context) async -> Timeline<Entry> {
        let store = PhoneStore.shared
        let printers = store?.printers ?? []
        if let store, !printers.isEmpty {
            store.record(await PrinterFetch.fetchAll(printers), at: Date())
        }
        let statuses = store?.statuses ?? []
        let now = Date()
        let entries = GlanceContent.phoneEntryDates(statuses, now: now).map {
            Entry(date: $0, cards: GlanceContent.phoneCards(printers, statuses: statuses, now: $0))
        }
        return Timeline(entries: entries, policy: .after(GlanceContent.phoneNextFetch(statuses, now: now)))
    }

    /// The widget gallery's example.
    static let sample: Printer = {
        var p = Printer(
            id: "", name: "X2D", state: "RUNNING", percent: 52, remainingS: 84 * 60, job: "Benchy",
            layer: 18, layerTotal: 29, eta: nil, filament: "PLA Matte", filamentRemain: 80
        )
        p.filamentColor = "F5C6A0FF"
        return p
    }()
}

struct EntryView: View {
    var entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let lines = entry.cards.first ?? GlanceContent.phone(nil, printer: nil, now: entry.date)
        switch family {
        case .accessoryCircular:
            Group {
                if let percent = lines.percent {
                    Gauge(value: Double(min(max(percent, 0), 100)), in: 0 ... 100) {
                        Image(systemName: lines.systemImage)
                    } currentValueLabel: {
                        Text("\(percent)")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                } else {
                    ZStack {
                        AccessoryWidgetBackground()
                        Image(systemName: lines.systemImage).font(.title2)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(lines.title), \(lines.short)")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.title).font(.headline).lineLimit(1)
                Text(lines.short).monospacedDigit().lineLimit(1)
                if let percent = lines.percent {
                    ProgressView(value: Double(min(max(percent, 0), 100)), total: 100)
                } else if let detail = lines.detail {
                    Text(detail).font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(lines.short, systemImage: lines.systemImage)
        case .systemMedium where entry.cards.count > 1:
            HStack(spacing: 16) {
                PhoneCard(lines: entry.cards[0])
                Divider()
                PhoneCard(lines: entry.cards[1])
            }
        case .systemMedium:
            PhoneCard(lines: lines, showsExtra: true)
        default:
            PhoneCard(lines: lines)
        }
    }
}
