import SwiftUI
import WidgetKit

/// First `max` guests plus the number that did not fit.
func guestGrid(_ guests: [Guest], max: Int = 8) -> (shown: [Guest], overflow: Int) {
    (Array(guests.prefix(max)), Swift.max(guests.count - max, 0))
}

/// avg/peak captions; the period is added only after a cross-period fallback.
func guestStatCaptions(_ g: Guest, dataPeriod: Period, entryPeriod: Period) -> (avg: String, peak: String) {
    let tag = dataPeriod == entryPeriod ? "" : " \(dataPeriod.label)"
    return ("avg\(tag) \(g.cpu.avg.map(Format.percent) ?? "—")",
            "peak\(tag) \(g.cpu.peak.map(Format.percent) ?? "—")")
}

struct GuestsWidgetView: View {
    let entry: PveEntry

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        Group {
            if let s = entry.snapshot {
                content(s)
            } else {
                ErrorContent(entry: entry, title: "Guests")
            }
        }
        // Taps outside the guest cards open the host.
        .widgetURL(entry.hostOpenURL)
    }

    private func content(_ s: Snapshot) -> some View {
        let grid = guestGrid(s.guests)
        let rows = (grid.shown.count + (grid.overflow > 0 ? 1 : 0) + 2) / 3
        return VStack(spacing: 8) {
            WidgetHeader(title: "Guests", period: entry.period, status: entry.staleLabel ?? summary(s.guests),
                         warning: entry.stale)
            GeometryReader { geo in
                let cardHeight = max((geo.size.height - CGFloat(max(rows - 1, 0)) * 6) / CGFloat(max(rows, 1)), 0)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(grid.shown, id: \.vmid) { g in
                        Link(destination: widgetOpenURL(target: "\(g.type)/\(g.vmid)")) {
                            GuestCard(guest: g, dataPeriod: entry.dataPeriod, entryPeriod: entry.period, compact: rows > 2)
                        }
                        .buttonStyle(.plain)
                        .frame(height: cardHeight)
                    }
                    if grid.overflow > 0 {
                        Text("+\(grid.overflow)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.06)))
                            .frame(height: cardHeight)
                    }
                }
            }
        }
    }

    private func summary(_ guests: [Guest]) -> String {
        let running = guests.filter { $0.status == "running" }.count
        let stopped = guests.count - running
        return stopped > 0 ? "\(running) running · \(stopped) stopped" : "\(running) running"
    }
}

struct GuestCard: View {
    let guest: Guest
    /// Period the avg/peak statistics cover, and the period the widget is set to.
    var dataPeriod: Period = .day
    var entryPeriod: Period = .day
    /// Tighter spacing for three rows of cards.
    var compact = false

    private var running: Bool { guest.status == "running" }
    private var captions: (avg: String, peak: String) { guestStatCaptions(guest, dataPeriod: dataPeriod, entryPeriod: entryPeriod) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 4) {
            title
            if running {
                metrics
            } else {
                Spacer(minLength: 0)
                Text(guest.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(running ? 0.06 : 0.03)))
        .opacity(running ? 1 : 0.55)
    }

    private var title: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(running ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(guest.name)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .widgetAccentable()
            Spacer(minLength: 2)
            Text("\(guest.type == "lxc" ? "CT" : "VM") \(guest.vmid)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder private var metrics: some View {
        row("CPU", ratio: guest.cpu.now, level: Threshold.cpu.level(guest.cpu.now), value: Format.percent(guest.cpu.now))
        if guest.cpu.series.count > 1 {
            ThresholdBarChart(series: guest.cpu.series, threshold: .cpu)
                .frame(minHeight: 6, maxHeight: .infinity)
        } else {
            Text("no history yet")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 6, maxHeight: .infinity)
        }
        HStack {
            Text(captions.avg)
            Spacer()
            Text(captions.peak)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        row("RAM", ratio: guest.mem.ratio, level: Threshold.mem.level(guest.mem.ratio),
            value: Format.usage(guest.mem.used, guest.mem.total))
        if let d = guest.disk {
            row("Disk", ratio: d.usage.ratio, level: Threshold.disk.level(d.usage.ratio), value: Format.free(d.used, d.total))
        } else {
            row("Disk", ratio: nil, level: .ok, value: "—")
        }
    }

    private func row(_ label: String, ratio: Double?, level: Level, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            if let ratio {
                LevelBar(ratio: ratio, level: level)
            } else {
                Capsule().fill(.primary.opacity(0.08)).frame(height: 4)
            }
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
                .widgetAccentable()
        }
        .font(.system(size: 10))
        .lineLimit(1)
    }
}
