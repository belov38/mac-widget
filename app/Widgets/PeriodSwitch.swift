import AppIntents
import SwiftUI
import WidgetKit

/// Segmented 24h / 1w / 1m switch; each segment runs SetPeriodIntent, which updates both widgets.
struct PeriodSwitch: View {
    let current: Period

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Period.allCases, id: \.self) { p in
                Button(intent: SetPeriodIntent(period: p)) {
                    Text(p.label)
                        .font(.system(size: 10, weight: p == current ? .bold : .medium))
                        .foregroundStyle(p == current ? .primary : .secondary)
                        .frame(width: 30, height: 16)
                        .background {
                            if p == current {
                                Capsule().fill(.primary.opacity(0.2)).widgetAccentable()
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.primary.opacity(0.07)))
    }
}
