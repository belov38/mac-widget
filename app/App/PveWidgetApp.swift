import AppKit
import SwiftUI
import WidgetKit

@main
struct PveWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The window is managed by AppDelegate so that URL launches from widget taps stay windowless.
    var body: some Scene {
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A normal launch (Finder, Dock, `open -a`) arrives as an "open application" Apple event;
        // a URL launch from a widget tap has no such event and stays windowless.
        // NSApplicationLaunchIsDefaultLaunchKey is not usable here: it is false for both.
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventClass == AEEventClass(kCoreEventClass), event?.eventID == AEEventID(kAEOpenApplication) {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    /// Opens the pve web UI for pvewidget://open?target=... links.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let target = openTarget(from: url), let dest = pveURL(for: target) else { continue }
            NSWorkspace.shared.open(dest)
        }
        // A URL-only launch has no window; quit so the app does not linger in the Dock.
        if shouldQuitAfterOpen(windowVisible: window?.isVisible == true) {
            NSApp.terminate(nil)
        }
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ContentView()))
            w.title = "PVE Widget"
            w.styleMask.remove(.resizable)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Development view: both widgets at Extra Large size with live data.
struct ContentView: View {
    @AppStorage("period", store: .group) private var periodRaw = Period.day.rawValue
    @State private var entry: PveEntry?
    @State private var topology: TopologyEntry?

    private var period: Period { Period(rawValue: periodRaw) ?? .day }

    var body: some View {
        VStack(spacing: 16) {
            Picker("Period", selection: $periodRaw) {
                ForEach(Period.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            HStack(spacing: 20) {
                WidgetFrame { HostWidgetView(entry: shown) }
                WidgetFrame { GuestsWidgetView(entry: shown) }
            }
            WidgetFrame {
                TopologyWidgetView(entry: topology ?? TopologyEntry(date: .now, topology: nil, stale: true, error: "Loading…"))
            }
        }
        .padding(20)
        .task {
            while !Task.isCancelled {
                topology = await makeTopologyEntry()
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .task(id: periodRaw) {
            WidgetCenter.shared.reloadAllTimelines()
            // Refresh every 5 minutes, like the widget timeline.
            while !Task.isCancelled {
                entry = await makeEntry(period: period, fetcher: SnapshotClient(), cache: .production, now: .now)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private var shown: PveEntry {
        entry ?? PveEntry(date: .now, period: period, snapshot: nil, stale: true, error: "Loading…")
    }
}

/// Approximates an Extra Large desktop widget: size, content margins and glass.
struct WidgetFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(width: WidgetSize.extraLarge.width, height: WidgetSize.extraLarge.height)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

enum WidgetSize {
    static let extraLarge = CGSize(width: 700, height: 330)
}
