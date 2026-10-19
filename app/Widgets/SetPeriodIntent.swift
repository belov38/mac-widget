import AppIntents
import WidgetKit

struct SetPeriodIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Period"

    @Parameter(title: "Period")
    var period: Period

    init() {}

    init(period: Period) {
        self.period = period
    }

    func perform() async throws -> some IntentResult {
        PeriodStore.set(period)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
