import SwiftUI
import XCTest

/// Renders both widget views from the golden fixture to PNGs for visual review.
/// The sandboxed test host writes into its container temp dir:
/// ~/Library/Containers/<app bundle id>/Data/tmp/pvewidget-preview
/// Skipped unless PVEWIDGET_RENDER=1 (pass TEST_RUNNER_PVEWIDGET_RENDER=1 to xcodebuild).
@MainActor
final class RenderPreviewTests: XCTestCase {
    private let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("pvewidget-preview", isDirectory: true)

    private func fixture() throws -> Snapshot {
        let url = try XCTUnwrap(Bundle(for: RenderPreviewTests.self).url(forResource: "snapshot.json", withExtension: nil))
        return try Snapshot.decode(Data(contentsOf: url))
    }

    private func render<V: View>(_ view: V, _ name: String, scheme: ColorScheme = .dark) throws {
        let framed = view
            .padding(16)
            .frame(width: 700, height: 330)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.92))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    func testRenderPreviews() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PVEWIDGET_RENDER"] == "1", "set PVEWIDGET_RENDER=1 to write preview PNGs")
        let s = try fixture()
        let fresh = PveEntry(date: .now, period: .day, snapshot: s, stale: false, error: nil)
        try render(HostWidgetView(entry: fresh), "host")
        try render(GuestsWidgetView(entry: fresh), "guests")
        try render(HostWidgetView(entry: fresh), "host-light", scheme: .light)
        try render(GuestsWidgetView(entry: fresh), "guests-light", scheme: .light)

        let topoURL = try XCTUnwrap(Bundle(for: RenderPreviewTests.self).url(forResource: "topology.json", withExtension: nil))
        let topo = try Topology.decode(Data(contentsOf: topoURL))
        let topoEntry = TopologyEntry(date: topo.generatedDate.addingTimeInterval(120), topology: topo, stale: false, error: nil)
        try render(TopologyWidgetView(entry: topoEntry), "topology")
        try render(TopologyWidgetView(entry: topoEntry), "topology-light", scheme: .light)

        var many = s
        many.guests += Snapshot.sample.guests.map { g in
            var g = g
            g.vmid += 10
            return g
        } + Snapshot.sample.guests.prefix(2).map { g in
            var g = g
            g.vmid += 20
            return g
        }
        let stale = PveEntry(date: .now, period: .week, snapshot: many, stale: true, error: "boom")
        try render(GuestsWidgetView(entry: stale), "guests-overflow-stale")

        let t0 = Date(timeIntervalSince1970: 0)
        let probe = VStack(spacing: 6) {
            ForEach([0.5, 0.8, 0.95], id: \.self) { v in
                ThresholdBarChart(series: (0..<10).map { i in
                    let avg = v - 0.3 + 0.01 * Double(i % 2)
                    return Point(t: t0.addingTimeInterval(Double(i)), avg: avg, max: i % 3 == 0 ? v : avg)
                }, threshold: .cpu)
            }
        }
        try render(probe, "chart-probe")

        let error = PveEntry(date: .now, period: .day, snapshot: nil, stale: true, error: "No data from pve")
        try render(HostWidgetView(entry: error), "error")
    }
}
