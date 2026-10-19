import SwiftUI
import WidgetKit

extension Level {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .yellow
        case .crit: .red
        }
    }
}

/// One vertical piece of a bar on the 0...1 axis, colored by the level of its top value
/// (and the bucket's pressure when there is one).
struct BarSegment: Equatable {
    let from: Double
    let to: Double
    let level: Level
}

/// Opaque base 0...avg plus, when max is higher, an overlay avg...max. Values are clamped to 0...1.
/// The base takes the level of avg with the mean pressure, the overlay of max with the peak pressure.
func barSegments(_ p: Point, _ rule: LevelRule) -> [BarSegment] {
    func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
    let avg = clamp(p.avg), top = clamp(Swift.max(p.max, p.avg))
    let base = BarSegment(from: 0, to: avg, level: rule.level(avg, pressure: p.pressureAvg))
    guard top > avg else { return [base] }
    return [base, BarSegment(from: avg, to: top, level: rule.level(top, pressure: p.pressureMax))]
}

func barSegments(_ p: Point, _ th: Threshold) -> [BarSegment] { barSegments(p, LevelRule(th)) }

/// Horizontal extents of count bars that fill width, separated by a small gap.
func barSlots(count: Int, width: CGFloat) -> [ClosedRange<CGFloat>] {
    guard count > 0, width > 0 else { return [] }
    let n = CGFloat(count)
    let gap = min(1, width / n * 0.3)
    let bar = (width - gap * (n - 1)) / n
    return (0..<count).map { i in
        let x = CGFloat(i) * (bar + gap)
        return x...(i == count - 1 ? width : x + bar)
    }
}

extension ClosedRange where Bound == CGFloat {
    var minX: CGFloat { lowerBound }
    var maxX: CGFloat { upperBound }
    var width: CGFloat { upperBound - lowerBound }
}

/// Bar chart of a 0...1 series: an opaque avg bar with a semi-transparent max bar on top.
struct ThresholdBarChart: View {
    let series: [Point]
    let rule: LevelRule

    init(series: [Point], rule: LevelRule) {
        self.series = series
        self.rule = rule
    }

    init(series: [Point], threshold: Threshold) {
        self.init(series: series, rule: LevelRule(threshold))
    }

    var body: some View {
        ZStack {
            layer(index: 0).widgetAccentable()
            layer(index: 1).opacity(0.35)
        }
    }

    /// Draws segment `index` of every bar (0 = avg base, 1 = max overlay).
    private func layer(index: Int) -> some View {
        Canvas { ctx, size in
            for (slot, p) in zip(barSlots(count: series.count, width: size.width), series) {
                let segs = barSegments(p, rule)
                guard index < segs.count else { continue }
                let s = segs[index]
                let rect = CGRect(x: slot.minX, y: size.height * (1 - s.to),
                                  width: slot.width, height: size.height * (s.to - s.from))
                ctx.fill(Path(rect), with: .color(s.level.color))
            }
        }
    }
}

/// Thin horizontal usage bar colored by level.
struct LevelBar: View {
    let ratio: Double
    let level: Level
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(level.color)
                    .frame(width: max(geo.size.width * min(max(ratio, 0), 1), ratio > 0 ? height : 0))
                    .widgetAccentable()
            }
        }
        .frame(height: height)
    }
}
