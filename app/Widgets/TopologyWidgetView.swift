import AppIntents
import SwiftUI
import WidgetKit

extension TPath.Kind {
    var color: Color {
        switch self {
        case .lan: .green
        case .direct: .blue
        case .derp: .orange
        case .peerRelay: .purple
        }
    }

    var label: String {
        switch self {
        case .lan: "LAN"
        case .direct: "direct"
        case .derp: "DERP"
        case .peerRelay: "relay"
        }
    }

    var dash: [CGFloat] {
        switch self {
        case .lan, .direct: []
        case .derp: [5, 3]
        case .peerRelay: [2, 2]
        }
    }
}

extension TNode {
    var color: Color {
        if !online { return .gray }
        return path?.kind.color ?? .red
    }

    var symbol: String {
        if parent != nil { return "cube" }
        switch os.lowercased() {
        case "macos": return "laptopcomputer"
        case "ios": return "iphone"
        case "android": return "smartphone"
        case "windows": return "pc"
        default: return "server.rack"
        }
    }

    /// Second label line: path and latency, or how long ago an offline node was seen.
    func detail(now: Date) -> String {
        guard online else {
            return lastSeenDate.map { "off · \(Format.ago($0, now: now))" } ?? "offline"
        }
        guard let p = path else { return "no reply" }
        // The edge color already tells the path kind; only the DERP region is added.
        let ms = Format.latency(p.ms)
        return p.kind == .derp ? "\(p.via) · \(ms)" : ms
    }
}

extension Format {
    /// "4ms", "587ms", "1.8s".
    static func latency(_ ms: Double) -> String {
        ms >= 1000 ? String(format: "%.1fs", ms / 1000) : String(format: "%.0fms", ms)
    }

    /// Coarse age: "5m", "3h", "4d".
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(now.timeIntervalSince(date), 0)
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }
}

/// Node order around the ring: pve in the middle of its guests (one cluster), then the rest by name.
func ringOrder(_ nodes: [TNode]) -> (nodes: [TNode], clusterSize: Int) {
    let guests = nodes.filter { $0.parent == "pve" }.sorted { $0.name < $1.name }
    let half = guests.count / 2
    let cluster = guests.prefix(half) + nodes.filter { $0.name == "pve" } + guests.dropFirst(half)
    let rest = nodes.filter { $0.name != "pve" && $0.parent != "pve" }.sorted { $0.name < $1.name }
    return (Array(cluster) + rest, cluster.count)
}

/// Points spaced evenly by arc length on an ellipse; slot `i` of `n`, with the cluster centred on the left.
struct RingLayout {
    let center: CGPoint
    let rx: CGFloat
    let ry: CGFloat
    private let samples: [CGPoint]
    private let cumulative: [CGFloat]

    init(center: CGPoint, rx: CGFloat, ry: CGFloat) {
        self.center = center
        self.rx = rx
        self.ry = ry
        let n = 720
        var pts: [CGPoint] = []
        var cum: [CGFloat] = [0]
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            let p = CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t))
            if let last = pts.last { cum.append(cum.last! + hypot(p.x - last.x, p.y - last.y)) }
            pts.append(p)
        }
        samples = pts
        cumulative = cum
    }

    var length: CGFloat { cumulative.last! }

    /// Point at arc length `s` (wrapped), measured clockwise from the rightmost point.
    func point(at s: CGFloat) -> CGPoint {
        var s = s.truncatingRemainder(dividingBy: length)
        if s < 0 { s += length }
        var lo = 0, hi = cumulative.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= s { lo = mid } else { hi = mid }
        }
        return samples[lo]
    }

    func slotArc(_ i: Int, of n: Int, clusterSize: Int) -> CGFloat {
        let step = length / CGFloat(max(n, 1))
        // Arc length length/2 is the leftmost point; centre the cluster there.
        let start = length / 2 - CGFloat(max(clusterSize - 1, 0)) / 2 * step
        return start + CGFloat(i) * step
    }
}

/// Radial scale: distance from the Mac grows with log latency; offline and silent nodes sit on the outer edge.
enum LatencyScale {
    static let minFactor: CGFloat = 0.42
    static let maxFactor: CGFloat = 0.86
    private static let lo = log10(2.0), hi = log10(1500.0)

    static func factor(ms: Double) -> CGFloat {
        let x = (log10(max(ms, 2)) - lo) / (hi - lo)
        return minFactor + (maxFactor - minFactor) * CGFloat(min(max(x, 0), 1))
    }

    static func factor(_ n: TNode) -> CGFloat {
        guard n.online, let p = n.path else { return 1 }
        return factor(ms: p.ms)
    }

    static let rings: [(ms: Double, label: String)] = [(10, "10ms"), (100, "100ms"), (1000, "1s")]
}

struct TopologyWidgetView: View {
    let entry: TopologyEntry

    var body: some View {
        if let t = entry.topology {
            content(t)
        } else {
            VStack {
                header(nil)
                Spacer()
                Text(entry.error ?? "Loading…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
        }
    }

    private func content(_ t: Topology) -> some View {
        VStack(spacing: 2) {
            header(t)
            GeometryReader { geo in
                graph(t, size: geo.size)
            }
            .invalidatableContent()
        }
    }

    private func status(_ t: Topology?) -> (String, Bool) {
        guard let t else { return ("", false) }
        let on = t.nodes.filter(\.online).count
        let age = entry.date.timeIntervalSince(t.generatedDate)
        let stale = entry.stale || age > 20 * 60
        let time = Format.stamp(t.generatedDate, now: entry.date)
        return ("\(on)/\(t.nodes.count) online · \(stale ? "data from " : "")\(time)", stale)
    }

    private func header(_ t: Topology?) -> some View {
        let (text, warning) = status(t)
        return HStack(spacing: 6) {
            Text("Tailnet").font(.system(size: 13, weight: .bold)).widgetAccentable()
            if let me = t?.me {
                Text(selfDetail(me))
                    .foregroundStyle(me.udp == false ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            if warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(text).foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Button(intent: RefreshTopologyIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 18)
                    .background(Capsule().fill(.primary.opacity(0.1)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }

    private func selfDetail(_ me: TSelf) -> String {
        let lan = me.lan.first ?? "no LAN address"
        if me.udp == false { return "\(lan) · UDP blocked" }
        let derp = me.preferredDerp ?? me.derp ?? "?"
        return "\(lan) · DERP \(derp)" + (me.derpMs.map { " \(Format.latency($0))" } ?? "")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([TPath.Kind.lan, .direct, .derp, .peerRelay], id: \.self) { k in
                HStack(spacing: 4) {
                    Capsule().fill(k.color).frame(width: 10, height: 3)
                    Text(k.label)
                }
            }
            Text("rings: 10ms · 100ms · 1s").padding(.top, 2)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func graph(_ t: Topology, size: CGSize) -> some View {
        let (nodes, clusterSize) = ringOrder(t.nodes)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rx = size.width / 2 - 118, ry = size.height / 2 - 30
        let ring = RingLayout(center: center, rx: rx, ry: ry)
        let points: [CGPoint] = nodes.indices.map { i in
            let p = ring.point(at: ring.slotArc(i, of: nodes.count, clusterSize: clusterSize))
            let f = LatencyScale.factor(nodes[i])
            return CGPoint(x: center.x + (p.x - center.x) * f, y: center.y + (p.y - center.y) * f)
        }

        return ZStack(alignment: .bottomLeading) {
            ForEach(LatencyScale.rings, id: \.ms) { r in
                let f = LatencyScale.factor(ms: r.ms)
                Ellipse()
                    .stroke(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .frame(width: 2 * rx * f, height: 2 * ry * f)
                    .position(center)
            }

            ForEach(Array(nodes.enumerated()), id: \.element.id) { i, n in
                edge(from: center, to: points[i])
                    .stroke(n.color.opacity(n.online ? 0.85 : 0.35), style: edgeStyle(n))
            }

            ForEach(Array(nodes.enumerated()), id: \.element.id) { i, n in
                let p = points[i]
                let side = labelSide(p, center: center, rx: rx, ry: ry)
                nodeIcon(n).position(p)
                nodeLabel(n, side: side).position(labelCenter(p, side: side))
            }

            Image(systemName: "laptopcomputer")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.primary.opacity(0.12)))
                .widgetAccentable()
                .position(center)

            legend
        }
        .frame(width: size.width, height: size.height)
    }

    /// Labels point away from the Mac: above/below near the top and bottom, beside the icon on the sides.
    private func labelSide(_ p: CGPoint, center: CGPoint, rx: CGFloat, ry: CGFloat) -> Edge {
        let ux = (p.x - center.x) / rx, uy = (p.y - center.y) / ry
        if abs(uy) >= abs(ux) * 0.9 { return uy < 0 ? .top : .bottom }
        return ux < 0 ? .leading : .trailing
    }

    private static let labelWidth: CGFloat = 104

    private func labelCenter(_ p: CGPoint, side: Edge) -> CGPoint {
        let w = Self.labelWidth / 2 + 14
        switch side {
        case .top: return CGPoint(x: p.x, y: p.y - 23)
        case .bottom: return CGPoint(x: p.x, y: p.y + 23)
        case .leading: return CGPoint(x: p.x - w, y: p.y)
        case .trailing: return CGPoint(x: p.x + w, y: p.y)
        }
    }

    /// Line from the edge of the centre circle to just outside the node icon.
    private func edge(from c: CGPoint, to p: CGPoint) -> Path {
        let dx = p.x - c.x, dy = p.y - c.y
        let len = max(hypot(dx, dy), 1)
        let start = CGPoint(x: c.x + dx / len * 20, y: c.y + dy / len * 20)
        let end = CGPoint(x: p.x - dx / len * 13, y: p.y - dy / len * 13)
        return Path { $0.move(to: start); $0.addLine(to: end) }
    }

    private func edgeStyle(_ n: TNode) -> StrokeStyle {
        guard n.online else { return StrokeStyle(lineWidth: 1, dash: [1, 3]) }
        guard let p = n.path else { return StrokeStyle(lineWidth: 1.2, dash: [1, 3]) }
        return StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: p.kind.dash)
    }

    private func nodeIcon(_ n: TNode) -> some View {
        Image(systemName: n.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(n.color)
            .frame(width: 22, height: 22)
            .background(Circle().fill(n.color.opacity(0.18)))
            .overlay(Circle().stroke(n.color.opacity(0.9), lineWidth: 1))
            .opacity(n.online ? 1 : 0.55)
    }

    private func nodeLabel(_ n: TNode, side: Edge) -> some View {
        let align: HorizontalAlignment = side == .leading ? .trailing : side == .trailing ? .leading : .center
        let frameAlign: Alignment = side == .leading ? .trailing : side == .trailing ? .leading : .center
        return VStack(alignment: align, spacing: 0) {
            Text(n.name).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(n.online ? .primary : .secondary)
            Text(n.detail(now: entry.date)).font(.system(size: 9, weight: .medium))
                .foregroundStyle(n.online && n.path == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .lineLimit(1)
        .frame(width: Self.labelWidth, alignment: frameAlign)
    }
}
