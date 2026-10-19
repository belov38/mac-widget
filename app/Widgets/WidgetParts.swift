import SwiftUI
import WidgetKit

extension PveEntry {
    /// Period the snapshot data actually covers (differs from `period` after a cross-period fallback).
    var dataPeriod: Period {
        snapshot?.period.flatMap(Period.init(rawValue:)) ?? period
    }

    /// Deep link to the host page; falls back to "pve" when there is no snapshot.
    var hostOpenURL: URL {
        widgetOpenURL(target: "node/\(snapshot?.host.name ?? "pve")")
    }

    /// "data from HH:mm" (with the date when not today) for stale entries, nil when fresh.
    var staleLabel: String? { staleLabel(now: .now) }

    func staleLabel(now: Date, tz: TimeZone = .current) -> String? {
        guard stale, let s = snapshot else { return nil }
        return "data from \(Format.stamp(s.generatedAt, now: now, tz))"
    }
}

/// Header row: title on the left, period switch centred, status on the right.
struct WidgetHeader: View {
    let title: String
    let period: Period
    let status: String
    var warning = false

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .bold)).widgetAccentable()
                Spacer(minLength: 0)
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(status).foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            PeriodSwitch(current: period)
        }
    }
}

/// Subtle translucent section card inside the widget.
struct SectionCard<Content: View>: View {
    var padding: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.06)))
    }
}

/// Small grey caption used for section titles.
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// Shown when there is no snapshot at all.
struct ErrorContent: View {
    let entry: PveEntry
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            WidgetHeader(title: title, period: entry.period, status: "")
            Spacer()
            Text(entry.error ?? "No data")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }
}

/// Percent without the "%" sign, for compact "avg 31 · peak 92" text.
func pct(_ r: Double?) -> String {
    r.map { String(format: "%.0f", $0 * 100) } ?? "—"
}
