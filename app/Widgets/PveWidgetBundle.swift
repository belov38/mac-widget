import SwiftUI
import WidgetKit

struct HostWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "host", provider: SnapshotProvider()) { entry in
            HostWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("PVE Host")
        .description("Load, memory, temperatures and storage of the pve host.")
        .supportedFamilies([.systemExtraLarge])
    }
}

struct GuestsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "guests", provider: SnapshotProvider()) { entry in
            GuestsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("PVE Guests")
        .description("CPU, memory and disk of the VMs and containers on pve.")
        .supportedFamilies([.systemExtraLarge])
    }
}

struct TopologyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TopologyWidgetKind, provider: TopologyProvider()) { entry in
            TopologyWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Tailnet")
        .description("How this Mac reaches each of your Tailscale nodes: LAN, direct or DERP.")
        .supportedFamilies([.systemExtraLarge])
    }
}

@main
struct PveWidgetBundle: WidgetBundle {
    var body: some Widget {
        HostWidget()
        GuestsWidget()
        TopologyWidget()
    }
}
