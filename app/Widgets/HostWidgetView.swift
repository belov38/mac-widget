import SwiftUI
import WidgetKit

struct HostWidgetView: View {
    let entry: PveEntry

    var body: some View {
        Group {
            if let s = entry.snapshot {
                content(s)
            } else {
                ErrorContent(entry: entry, title: "pve")
            }
        }
        .widgetURL(entry.hostOpenURL)
    }

    private func content(_ s: Snapshot) -> some View {
        let h = s.host
        let status = entry.staleLabel ?? "up \(Format.uptime(h.uptimeS)) · \(Format.time(s.generatedAt))"
        return VStack(spacing: 8) {
            WidgetHeader(title: h.name, period: entry.period, status: status, warning: entry.stale)
            HStack(spacing: 8) {
                cpu(h)
                mem(h)
            }
            // Bottom cards share the taller one's natural height; charts take the rest.
            HStack(spacing: 8) {
                temps(h.temps)
                storages(h.storages, io: h.ioPressure)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cpu(_ h: Host) -> some View {
        SectionCard {
            Caption("CPU · now / \(entry.dataPeriod.label)")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                BigNumber(text: Format.percent(h.cpu.now))
                Text("avg \(pct(h.cpu.avg)) · peak \(pct(h.cpu.peak)) · load \(String(format: "%.1f", h.load.first ?? 0))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            ThresholdBarChart(series: h.cpu.series, rule: .hostCPU)
                .frame(minHeight: 30)
        }
    }

    private func mem(_ h: Host) -> some View {
        SectionCard {
            Caption("RAM · now / \(entry.dataPeriod.label)")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                BigNumber(text: Format.usage(h.mem.used, h.mem.total))
                Text("avg \(pct(h.mem.avg)) · peak \(pct(h.mem.peak)) · swap \(Format.bytes(h.swap.used))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            ThresholdBarChart(series: h.mem.series, rule: .hostMem)
                .frame(minHeight: 30)
        }
    }

    private func temps(_ temps: [Temp]) -> some View {
        SectionCard {
            Caption("Temperatures")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3),
                      alignment: .leading, spacing: 3) {
                ForEach(temps, id: \.id) { t in
                    HStack(spacing: 3) {
                        Text(t.label).foregroundStyle(.secondary).lineLimit(1)
                        Text(String(format: "%.0f°", t.value))
                            .fontWeight(.semibold)
                            .foregroundStyle(t.level == .ok ? Color.primary : t.level.color)
                            .widgetAccentable()
                    }
                    .font(.system(size: 10.5))
                }
            }
        }
    }

    private func storages(_ storages: [Storage], io: Pressure?) -> some View {
        SectionCard {
            HStack(spacing: 4) {
                Caption("Storage")
                Spacer(minLength: 4)
                if let io, let now = io.now ?? io.avg {
                    ioWait(now: now, peak: io.peak)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(storages, id: \.id) { st in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(st.label)
                            Spacer(minLength: 4)
                            Text("\(Format.bytes(st.used)) / \(Format.bytes(st.total))").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        LevelBar(ratio: st.usage.ratio, level: Threshold.disk.level(st.usage.ratio))
                    }
                }
            }
        }
    }
}

/// "IO wait 3% · peak 15%": share of time tasks waited for disk, values colored by level.
@MainActor private func ioWait(now: Double, peak: Double?) -> some View {
    func value(_ v: Double, _ base: Color) -> Text {
        let level = Threshold.ioPressure.level(v)
        return Text(Format.percent(v)).foregroundStyle(level == .ok ? base : level.color)
    }
    return HStack(spacing: 3) {
        Text("IO wait").foregroundStyle(.secondary)
        value(now, .primary).fontWeight(.semibold).widgetAccentable()
        if let peak {
            Text("· peak").foregroundStyle(.secondary)
            value(peak, .secondary)
        }
    }
    .font(.system(size: 10))
    .lineLimit(1)
}

/// Large "now" value.
struct BigNumber: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .widgetAccentable()
    }
}
