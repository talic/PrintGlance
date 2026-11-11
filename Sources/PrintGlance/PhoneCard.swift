import SwiftUI

/// The iPhone widget's card, also shown in the iPhone app. Here so the Mac tests can read and render it.
struct PhoneCard: View {
    var lines: PhoneLines
    /// Layer and filament, where there is room: the medium widget and the app.
    var showsExtra = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lines.title)
                .font(.headline)
                .lineLimit(1)
            if !lines.state.isEmpty {
                Text(lines.state)
                    .font(.subheadline)
                    .foregroundStyle(lines.alert ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if let hero = lines.hero {
                Text(hero)
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if let detail = lines.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(showsExtra ? 3 : 2)
            }
            if let percent = lines.percent {
                HStack(spacing: 6) {
                    ProgressView(value: Double(min(max(percent, 0), 100)), total: 100)
                        .tint(lines.alert ? .orange : .primary)
                    Text("\(percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if showsExtra {
                ForEach(lines.extra, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if let footer = lines.footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
